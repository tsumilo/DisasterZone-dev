if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/UILayout.lua", ...) then return end -- DisasterZone Games/Disastercraft/UILayout.lua
-- CraftUI.Build(name, parent): makes a frame tree from the client's own layout (Layouts.lua: Blizzard's FrameXML
-- with its templates expanded) - every frame, texture and font string where the client puts it, sized and textured
-- as the client does. Returns the root and `refs`, the widgets by their Blizzard name ("QuestFrameAcceptButton")
-- and by key path ("Inset"). Scripts are not carried over: the game's behaviour is wired in UIWindows / UIHud.
-- Panel buttons (UIPanelButtonTemplate) get their pressed / disabled art swaps here, as Blizzard's scripts do.
local addonName, ns = ...

local UI = ns.CraftUI
local L = ns.CraftLayouts or {}
local max = math.max

local FRAME_KIND = { Frame = "Frame", Button = "Button", CheckButton = "CheckButton", ScrollFrame = "ScrollFrame",
                     StatusBar = "StatusBar", EditBox = "EditBox", Slider = "Slider", PlayerModel = "DressUpModel",
                     DressUpModel = "DressUpModel", ModelScene = "ModelScene", Cooldown = "Cooldown",
                     MessageFrame = "MessageFrame", ScrollingMessageFrame = "ScrollingMessageFrame",
                     SimpleHTML = "SimpleHTML", Model = "Model", GameTooltip = "Frame", TabardModel = "Frame",
                     CinematicModel = "Frame", ColorSelect = "Frame", Minimap = "Frame" }

-- the global strings the layouts name (the client has them all; the offline mock only some)
local STRINGS = { ACCEPT = "Accept", DECLINE = "Decline", CANCEL = "Cancel", COMPLETE_QUEST = "Complete Quest",
                  CONTINUE = "Continue", GOODBYE = "Goodbye", ITEMS = "Items", PREV = "Prev", NEXT = "Next",
                  CLOSE = "Close", OKAY = "Okay", YES = "Yes", NO = "No", TRAIN = "Train", EXIT = "Exit",
                  ABANDON_QUEST = "Abandon Quest", SHARE_QUEST = "Share Quest", TRACK_QUEST = "Track Quest",
                  QUEST_LOG = "Quest Log", SPELLBOOK = "Spellbook", MERCHANT = "Merchant", BUYBACK = "Buyback",
                  CHARACTER = "Character", REPUTATION = "Reputation", SKILLS = "Skills", HONOR = "Honor",
                  PET = "Pet", SELL_ALL_JUNK_ITEMS = "Sell Junk", REPAIR_ALL_ITEMS = "Repair All Items",
                  QUEST_OBJECTIVES = "Quest Objectives", REWARD_ITEMS_ONLY = "You will receive:",
                  REWARD_CHOICES = "You will be able to choose one of these rewards:",
                  REWARDS = "Rewards", REWARD_ITEMS = "You will also receive:", QUEST_DESCRIPTION = "Description",
                  PAGE_NUMBER = "Page %d", TRAINER_COST = "Cost:", NEED = "Need", GREED = "Greed", PASS = "Pass",
                  TRACK_QUEST = "Track", QUESTLOG_NO_QUESTS_TEXT = "No Active Quests", ALL = "All",
                  QUEST_LOG_COUNT_TEMPLATE = "Quests: %d/%d", QUEST_REWARDS = "Rewards", COMPLETE = "Complete",
                  PLAYER_LEVEL = "Level %s %s %s", COSTS_LABEL = "Cost:", FILTER = "Filter" }

local function Str(s)
    if not s then return nil end
    local g = _G[s]
    if type(g) == "string" then return g end
    return STRINGS[s] or s
end
UI.Str = Str

local function ApplySize(o, sz)
    if not sz then return end
    if sz[1] and sz[1] > 0 and sz[2] and sz[2] > 0 then o:SetSize(sz[1], sz[2])
    elseif sz[1] and sz[1] > 0 then o:SetWidth(sz[1])
    elseif sz[2] and sz[2] > 0 then o:SetHeight(sz[2]) end
end

-- anchors: relativeTo by Blizzard name, relativeKey as a "$parent.$parent.Key" walk
local function Resolve(ctx, owner, a)
    if a.key then
        local cur = owner
        for part in a.key:gmatch("[^%.]+") do
            if part == "$parent" then cur = cur.parentObj or (cur.GetParent and cur:GetParent())
            else cur = cur and (cur[part] or (cur.keys and cur.keys[part])) end
            if not cur then break end
        end
        return cur
    end
    if a.to then return ctx.refs[a.to] end
    return nil
end

local function ApplyAnchors(ctx, o, d, parent)
    if d.all then o:SetAllPoints(parent) return end
    for _, a in ipairs(d.anchors or {}) do
        local rel = Resolve(ctx, o, a) or parent
        local ok = pcall(o.SetPoint, o, a.p or "CENTER", rel, a.rp or a.p or "CENTER", a.x or 0, a.y or 0)
        if not ok then pcall(o.SetPoint, o, a.p or "CENTER", parent, a.rp or a.p or "CENTER", a.x or 0, a.y or 0) end
    end
end

local function SetTex(t, d)
    if d.atlas and t.SetAtlas then
        local ok = pcall(t.SetAtlas, t, d.atlas, d.useAtlasSize and true or false)
        if not ok then t:SetTexture(nil) end
    elseif d.file then
        t:SetTexture(d.file)
    elseif d.color then
        if type(d.color) == "table" then t:SetColorTexture(d.color[1], d.color[2], d.color[3], d.color[4] or 1) end
    end
    if d.coords then
        if #d.coords == 8 then t:SetTexCoord(unpack(d.coords)) else t:SetTexCoord(d.coords[1], d.coords[2], d.coords[3], d.coords[4]) end
    end
    if d.color and type(d.color) == "table" and (d.file or d.atlas) then
        t:SetVertexColor(d.color[1], d.color[2], d.color[3], d.color[4] or 1)
    end
    if d.blend then pcall(t.SetBlendMode, t, d.blend) end
    if d.hTile and t.SetHorizTile then t:SetHorizTile(true) end
    if d.vTile and t.SetVertTile then t:SetVertTile(true) end
    if d.desat and t.SetDesaturated then t:SetDesaturated(true) end
end

local function Register(ctx, o, d, parentObj)
    if d.name then ctx.refs[d.name] = o end
    if d.key and parentObj then parentObj[d.key] = o end
    if d.arr and parentObj then
        parentObj[d.arr] = parentObj[d.arr] or {}
        table.insert(parentObj[d.arr], o)
    end
    o.parentObj = parentObj
end

local function MakeRegion(ctx, owner, d)
    local o
    if d.t == "FontString" then
        o = owner:CreateFontString(nil, d.layer or "OVERLAY")
        local fo = d.font and _G[d.font]
        if fo and type(fo) == "table" and o.SetFontObject then o:SetFontObject(fo)
        else o:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 12, "") end
        if d.text then o:SetText(Str(d.text)) end
        if d.jh then o:SetJustifyH(d.jh) end
        if d.jv then o:SetJustifyV(d.jv) end
        if d.tcolor and type(d.tcolor) == "table" then o:SetTextColor(d.tcolor[1], d.tcolor[2], d.tcolor[3], d.tcolor[4] or 1) end
        if d.wrap ~= nil and o.SetWordWrap then o:SetWordWrap(d.wrap) end
        if d.lines and o.SetMaxLines then pcall(o.SetMaxLines, o, d.lines) end
    elseif d.t == "MaskTexture" then
        -- (the round portrait cut: the textures it names get it once they all exist, in UI.Build)
        if not owner.CreateMaskTexture then return nil end
        o = owner:CreateMaskTexture(nil, d.layer or "ARTWORK", nil, d.sub)
        if d.file then
            if not pcall(o.SetTexture, o, d.file, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE") then o:SetTexture(d.file) end
        end
        if d.masked then ctx.masks[#ctx.masks + 1] = { o, d.masked, owner } end
    elseif d.t == "Line" then
        return nil
    else
        o = owner:CreateTexture(nil, d.layer or "ARTWORK", nil, d.sub)
        SetTex(o, d)
    end
    ApplySize(o, d.size)
    if d.alpha then o:SetAlpha(d.alpha) end
    if d.hidden then o:Hide() end
    Register(ctx, o, d, owner)
    ctx.pending[#ctx.pending + 1] = { o, d, owner }
    return o
end

-- Blizzard's panel button: its three pieces swap to the pressed / disabled art
local function PanelButtonArt(b)
    local l, m, r = b.Left, b.Middle, b.Right
    if not (l and m and r) then return end
    local function set(state)
        local file = "Interface\\Buttons\\UI-Panel-Button-" .. state
        l:SetTexture(file) m:SetTexture(file) r:SetTexture(file)
    end
    b:HookScript("OnMouseDown", function(self) if self:IsEnabled() then set("Down") end end)
    b:HookScript("OnMouseUp", function(self) if self:IsEnabled() then set("Up") end end)
    b:HookScript("OnDisable", function() set("Disabled") end)
    b:HookScript("OnEnable", function() set("Up") end)
    b:HookScript("OnShow", function(self) set(self:IsEnabled() and "Up" or "Disabled") end)
end

local function MakeFrame(ctx, parent, d, parentObj)
    local kind = FRAME_KIND[d.t] or "Frame"
    local inherits
    for _, m in ipairs(d.missing or {}) do
        if m == "CooldownFrameTemplate" then kind, inherits = "Cooldown", m end
        if m == "WowStyle1DropdownTemplate" then kind, inherits = "DropdownButton", m end
    end
    local ok, f = pcall(CreateFrame, kind, nil, parent, inherits)
    if not ok or not f then f = CreateFrame("Frame", nil, parent) end
    f.keys = {}
    Register(ctx, f, d, parentObj)
    ApplySize(f, d.size)
    -- (no frameStrata: inside the game panel every frame keeps the panel's strata; frame levels order them)
    if d.useParentLevel and parent.GetFrameLevel then f:SetFrameLevel(parent:GetFrameLevel()) end
    if d.mouse ~= nil and f.EnableMouse then f:EnableMouse(d.mouse) end
    if d.alpha then f:SetAlpha(d.alpha) end
    if d.id and f.SetID then f:SetID(d.id) end
    for k, v in pairs(d.kv or {}) do f[k] = v end
    for _, r in ipairs(d.regions or {}) do MakeRegion(ctx, f, r) end
    -- button art and text
    if d.btex and (kind == "Button" or kind == "CheckButton" or kind == "Slider" or kind == "StatusBar") then
        for slot, td in pairs(d.btex) do
            if kind == "StatusBar" and slot == "BarTexture" then
                if td.file then f:SetStatusBarTexture(td.file) elseif td.atlas and f.SetStatusBarAtlas then pcall(f.SetStatusBarAtlas, f, td.atlas) end
            elseif kind == "Slider" and slot == "ThumbTexture" then
                local t = f:CreateTexture(nil, "OVERLAY")
                SetTex(t, td)
                ApplySize(t, td.size)
                f:SetThumbTexture(t)
            else
                local t = f:CreateTexture(nil, slot == "HighlightTexture" and "HIGHLIGHT" or "ARTWORK")
                SetTex(t, td)
                ApplySize(t, td.size)
                if td.name then ctx.refs[td.name] = t end
                local setter = "Set" .. slot
                if f[setter] then pcall(f[setter], f, t) end
                if td.anchors or td.all then ctx.pending[#ctx.pending + 1] = { t, td, f, true } end
                if td.key then f[td.key] = t end
            end
        end
    end
    if d.barColor and type(d.barColor) == "table" and f.SetStatusBarColor then
        f:SetStatusBarColor(d.barColor[1], d.barColor[2], d.barColor[3], d.barColor[4] or 1)
    end
    if d.buttonText and f.SetFontString then
        local fs = MakeRegion(ctx, f, d.buttonText)
        if fs then pcall(f.SetFontString, f, fs) end
    end
    if d.fonts and f.SetNormalFontObject then
        for slot, style in pairs(d.fonts) do
            local fo = _G[style]
            if fo and type(fo) == "table" and f["Set" .. slot .. "Object"] then pcall(f["Set" .. slot .. "Object"], f, fo) end
        end
    end
    if d.text and f.SetText then pcall(f.SetText, f, Str(d.text)) end
    if d.hit and f.SetHitRectInsets then f:SetHitRectInsets(d.hit[1], d.hit[2], d.hit[3], d.hit[4]) end
    for _, c in ipairs(d.frames or {}) do
        local cf = MakeFrame(ctx, f, c, f)
        if c.scrollChild and f.SetScrollChild then pcall(f.SetScrollChild, f, cf) end
    end
    if f.Left and f.Middle and f.Right and (kind == "Button") then PanelButtonArt(f) end
    if d.hidden then f:Hide() end
    ctx.pending[#ctx.pending + 1] = { f, d, parent }
    return f
end

-- name: a root of Layouts.lua; parent: our frame; names: the refs of a frame built before it, which its anchors may
-- name (PaperDollFrame's level line hangs under CharacterFrame's name). -> root, refs (its own names)
function UI.Build(name, parent, names)
    local d = L[name]
    if not d then return nil, {} end
    local ctx = { refs = setmetatable({}, { __index = names }), pending = {}, masks = {} }
    local root = MakeFrame(ctx, parent, d, nil)
    for _, m in ipairs(ctx.masks) do
        for _, k in ipairs(m[2]) do
            local t = m[3][k] or ctx.refs[k]
            if t and t.AddMaskTexture then t:AddMaskTexture(m[1]) end
        end
    end
    -- anchors last: everything they name exists now (the root's own anchors are the caller's business)
    for _, p in ipairs(ctx.pending) do
        local o, dd, owner = p[1], p[2], p[3]
        if o ~= root then
            if dd.anchors or dd.all then
                o:ClearAllPoints()
                ApplyAnchors(ctx, o, dd, owner)
            elseif p[4] then
            elseif not (o.GetNumPoints and o:GetNumPoints() > 0) then
                -- (no anchors: a sized region sits in the middle of its parent, an unsized one fills it - the
                -- client's rule)
                local sz = dd.size
                if sz and ((sz[1] or 0) > 0 or (sz[2] or 0) > 0) then o:SetPoint("CENTER", owner, "CENTER", 0, 0)
                else o:SetAllPoints(owner) end
            end
        end
    end
    root.refs = ctx.refs
    return root, ctx.refs
end

function UI.HasLayout(name) return L[name] ~= nil end

-- raises (or lowers) a frame and everything in it together, keeping their order (a parent's new level alone
-- would leave its children under its own textures)
function UI.SetLevelTree(f, level)
    local delta = level - (f:GetFrameLevel() or 0)
    if delta == 0 then return end
    local function walk(x)
        x:SetFrameLevel(max(0, (x:GetFrameLevel() or 0) + delta))
        for _, c in ipairs({ x:GetChildren() }) do walk(c) end
    end
    walk(f)
end
