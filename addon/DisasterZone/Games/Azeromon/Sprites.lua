if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Sprites.lua", ...) then return end -- DisasterZone Games/Azeromon/Sprites.lua
-- ns.AzeroSprites: Azeromon's pixel beasts. Every species' own model, rendered and pixelized in the dev kit
-- (dev/generators/gen_azeromon_beasts.py) at the battle screen's game-pixel size, drawn here as textures with
-- nearest filtering at a whole-number scale, so beasts and the pixel world share one look. Two views: "f" (front,
-- the foe) and "a" (back, your own beast). Clips: idle (played back and forth), attack, attack2, special, hit, faint.
-- The art index is Games/Azeromon/BeastArt.lua; its strings are decoded the first time a beast is shown.
-- UI.lua's model frames hold one of these and fall back to the 3D model when a beast has no art (or the art set on
-- disk is older than the one the index needs: an in-game update carries code, never art).
local addonName, ns = ...

local S = {}
ns.AzeroSprites = S

local floor, max, min, random = math.floor, math.max, math.min, math.random
local tonumber, gmatch = tonumber, string.gmatch

-- frames a second per clip; the idle is slow, a hit is quick
local FPS = { idle = 6, attack = 12, attack2 = 12, special = 10, hit = 12, faint = 10 }

local decoded = {}            -- [key] = { f = { [clip] = { loop, frames = { { x, y, w, h, lx, bt }, ... } } }, a = ... }

-- When true, every beast is drawn as its 3D model (/dz azeromon look 3d, and tests of the model fitting).
S.off = false

local function Art()
    local art = ns.AzeroBeastArt
    if not art or not ns:HasAssets(art.asset or 0) then return nil end
    return art
end

local function DecodeView(str)
    local clips = {}
    for name, loop, nums in gmatch(str or "", "(%w+)=(%d):([%-%d,]*)") do
        local frames, cur = {}, {}
        for n in gmatch(nums, "%-?%d+") do
            cur[#cur + 1] = tonumber(n)
            if #cur == 6 then frames[#frames + 1] = cur cur = {} end
        end
        clips[name] = { loop = loop == "1", frames = frames }
    end
    return clips
end

local function Beast(key)
    local art = Art()
    local b = art and art.beasts[key]
    if not b then return nil end
    local d = decoded[key]
    if not d then
        d = { info = b, f = DecodeView(b.f), a = DecodeView(b.a) }
        decoded[key] = d
    end
    return d
end
S._Beast = Beast

-- The art for a species: its shiny skin when it has one, else its plain art (and glow = true: drawn in a golden
-- light, as the 3D model was). nil when there is no art.
function S.Key(sp, shiny)
    if S.off or type(sp) ~= "string" then return nil end
    local art = Art()
    if not art then return nil end
    if shiny and art.beasts[sp .. "_s"] then return sp .. "_s", false end
    if art.beasts[sp] then return sp, shiny and true or false end
    return nil
end

-- the whole-number scale at which a beast fits a w x h frame (at most `cap`)
function S.FitScale(key, view, w, h, cap)
    local d = Beast(key)
    if not d then return 1 end
    local px = view == "a" and (d.info.apx or d.info.px) or d.info.px
    local k = floor(min((h or 0) * 0.8 / max(1, px), (w or 0) * 0.92 / max(1, d.info.iw or px)))
    return max(1, min(cap or 4, k))
end

---------------------------------------------------------------------------
-- A sprite on a frame
---------------------------------------------------------------------------

local Sprite = {}
Sprite.__index = Sprite

function S.New(frame)
    local self = setmetatable({ frame = frame }, Sprite)
    self.tex = frame:CreateTexture(nil, "ARTWORK")
    self.tex:Hide()
    return self
end

-- Show beast `key` in view "f" / "a" at `scale` (game pixel -> UI pixels), feet `lift` UI pixels above the
-- frame's bottom centre. glow: the golden light of a shiny with no skin of its own.
function Sprite:Set(key, view, scale, lift, glow)
    local d = Beast(key)
    if not d then self:Hide() return false end
    self.key, self.view, self.scale, self.lift = key, view or "f", scale or 3, lift or 0
    self.clips = d[self.view]
    self.glow = glow and true or false
    local art = Art()
    if self.file ~= d.info.tex then
        self.file = d.info.tex
        local path = art.dir .. d.info.tex
        local ok = pcall(self.tex.SetTexture, self.tex, path, nil, nil, "NEAREST")
        if not ok then self.tex:SetTexture(path) end
        if self.tex.SetSnapToPixelGrid then pcall(self.tex.SetSnapToPixelGrid, self.tex, false) end
        if self.tex.SetTexelSnappingBias then pcall(self.tex.SetTexelSnappingBias, self.tex, 0) end
    end
    self.tw, self.th = d.info.w, d.info.h
    self.dark = 0
    self:Tint()
    self:Play("idle")
    self.tex:Show()
    return true
end

function Sprite:Hide()
    self.key, self.clips = nil, nil
    self.tex:Hide()
end

function Sprite:Tint()
    local v = 1 - (self.dark or 0)
    if self.glow then
        local c = ns.AzeroData.SHINY_GLOW or { 1, 0.85, 0.45 }
        local m = max(c[1], c[2], c[3], 0.01)
        self.tex:SetVertexColor(v * c[1] / m, v * c[2] / m, v * c[3] / m)
    else
        self.tex:SetVertexColor(v, v, v)
    end
end

-- 0 = normal, 1 = a black silhouette (the evolution)
function Sprite:SetDark(a)
    self.dark = a or 0
    if self.key then self:Tint() end
end

-- Play a clip: idle loops back and forth; the others play once, then the idle (a faint stays on its last frame).
function Sprite:Play(name)
    local clips = self.clips
    if not clips then return end
    if name == "attack" and clips.attack2 and #clips.attack2.frames > 0 and random(2) == 2 then name = "attack2" end
    local c = clips[name] or clips.idle
    if not c or #c.frames == 0 then return end
    local seq = {}
    for i = 1, #c.frames do seq[#seq + 1] = i end
    if c.loop then for i = #c.frames - 1, 2, -1 do seq[#seq + 1] = i end end
    self.clip, self.cur, self.seq, self.pos, self.t = name, c, seq, 1, 0
    self.fps = FPS[name] or 10
    self:Draw()
end

-- WoW animation ids the battle asks for -> clips
local BY_ANIM = { [0] = "idle", [1] = "faint", [8] = "hit", [9] = "hit", [10] = "hit",
                  [51] = "special", [52] = "special", [53] = "special", [54] = "special", [55] = "special" }
function Sprite:Anim(id)
    self:Play(BY_ANIM[id] or "attack")
end

function Sprite:Update(dt)
    if not self.key or not self.seq then return end
    self.t = self.t + (dt or 0)
    local step = 1 / self.fps
    if self.t < step then return end
    self.t = self.t - step
    if self.t > step then self.t = 0 end
    if self.pos < #self.seq then
        self.pos = self.pos + 1
    elseif self.cur.loop then
        self.pos = 1
    elseif self.clip ~= "faint" then
        self:Play("idle")
        return
    else
        return
    end
    self:Draw()
end

function Sprite:Draw()
    local f = self.cur and self.cur.frames[self.seq[self.pos]]
    if not f then return end
    local k, tex = self.scale, self.tex
    local x, y, w, h, lx, bt = f[1], f[2], f[3], f[4], f[5], f[6]
    tex:SetTexCoord(x / self.tw, (x + w) / self.tw, y / self.th, (y + h) / self.th)
    tex:SetSize(w * k, h * k)
    tex:ClearAllPoints()
    tex:SetPoint("BOTTOMLEFT", self.frame, "BOTTOM", lx * k, bt * k + self.lift)
end

-- what is on screen (tests)
function Sprite:State()
    return { key = self.key, view = self.view, clip = self.clip, frame = self.seq and self.seq[self.pos],
             scale = self.scale, glow = self.glow, shown = self.tex:IsShown() }
end
