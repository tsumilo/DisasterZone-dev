if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/Outfit.lua", ...) then return end -- DisasterZone Games/Disastercraft/Outfit.lua
-- The hero's pixel sprite wears its gear, like a WoW character: a bare human body and, on top, one layer per item
-- on (OutfitData.lua, made by dev/generators/gen_dc_outfits.py), stacked in the order the client paints a
-- character - shirt, legs, boots, wrists, chest, hands, belt, tabard, cape, shield / off-hand, weapon. Put an
-- item on or take it off and the next frame shows it.
local addonName, ns = ...

local UI = ns.CraftUI
local O = ns.CraftOutfit

local SLOTS = { 4, 7, 8, 9, 5, 10, 6, 19, 15, 17, 16 }      -- the slots that show (rings, trinkets, ranged do not)
local stacks, frames = {}, {}

-- the layers of what a character wears, body first: { layer, ... } (cached by sex + gear). A layer: 32 frames x
-- { sheet, x, y, w, h, ox, oy } (frame = column * 4 + facing; sheet 0 = nothing shows in that frame)
local function Stack(c)
    local sex = c.sex or 0
    local key = sex
    for _, s in ipairs(SLOTS) do key = key .. "," .. (c.equip and c.equip[s] or 0) end
    local st = stacks[key]
    if st then return st, key end
    st = { O.layers[O.body[sex]] }
    local worn = {}
    for i, s in ipairs(SLOTS) do
        local id = c.equip and c.equip[s]
        local l = id and O.items[sex] and O.layers[O.items[sex][id]]
        if l then
            local it = ns.Craft.D.items[id]
            worn[#worn + 1] = { l, (O.order[it and it.inv or 0] or 0) * 100 + i }
        end
    end
    table.sort(worn, function(a, b) return a[2] < b[2] end)
    for _, w in ipairs(worn) do st[#st + 1] = w[1] end
    stacks[key] = st
    return st, key
end

-- the textures to stack for player unit u in one frame: kind "walk" (col 0-2: stride, stand, stride) or "act"
-- (col 0-4: wind-up, strike, spell ready, spell release, dead); face 0 down, 1 left, 2 right, 3 up.
-- -> { { file, l, r, t, b, x, y, w, h }, ... } (x, y, w, h: px in the sprite's 32 px cell from its top-left;
-- texcoords on the file), or nil when there is no outfit data (draw the old sprite)
function UI.OutfitLayers(u, kind, col, face)
    if not (O and O.layers and O.body and O.layers[O.body[0] or 0]) then return nil end
    local c = u and (u.char or u)
    if not c or not c.equip then return nil end
    local st, key = Stack(c)
    local bc = (kind == "act" and 3 or 0) + (col or 0)
    local fkey = key .. "|" .. bc .. "|" .. (face or 0)
    local out = frames[fkey]
    if out then return out end
    out = {}
    local b = (bc * 4 + (face or 0)) * 7
    for _, l in ipairs(st) do
        local n = l[b + 1]
        if n and n > 0 then
            local x, y, w, h, ox, oy = l[b + 2], l[b + 3], l[b + 4], l[b + 5], l[b + 6], l[b + 7]
            local sw, sh = O.sizes[n][1], O.sizes[n][2]
            out[#out + 1] = { O.sheets[n], x / sw, (x + w) / sw, y / sh, (y + h) / sh, ox, oy, w, h }
        end
    end
    frames[fkey] = out
    return out
end

-- (the caches only grow with new gear sets; a reload empties them)
function UI.OutfitReset() stacks, frames = {}, {} end
