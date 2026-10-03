if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Trainer/Room.lua", ...) then return end -- DisasterZone Games/Trainer/Room.lua
-- ns.TrainerRoom: the Raid Trainer's room renderer (v2, dev/docs/trainer_renderer_v2/spec.md).
--
-- The room is Blizzard's own mesh (ns.TrainerFloors.<key>.mesh). Every piece of it is a 1 x 1 Texture whose four
-- corners are bent onto where the camera sees them (SetVertexOffset). A texture has no depth test, so the room is
-- painted back to front in the exact order of the mesh's BSP tree: at every node the side the camera is not on,
-- then the node's own triangles, then the camera's side. That order is right from any viewpoint.
--  * The nodes are grouped into cluster frames: a whole subtree of at most 32 nodes, or such a subtree and its
--    parent, so a frame's nodes always come one after the other in that order. The frames are stacked by frame
--    level under the single ModelScene; inside a frame every node has its own place (draw layer + sublevel, the
--    even places), the odd place after a node is for the mark lines lying on it. Textures never change frame:
--    when the order changes, only frame levels and the sublevels of textures move.
--  * A triangle and its quad mate (the generator's pair list) are one texture; the client splits a texture along
--    its lower-left - upper-right diagonal, which is the edge the two share.
--  * A texture maps its picture affinely, a camera sees it in perspective: along an edge whose ends are d1 and d2
--    deep and L px apart the picture is off by at most L |sqrt d1 - sqrt d2| / (sqrt d1 + sqrt d2) (spec A.1),
--    and nowhere inside a piece by more than on its worst edge. A piece is drawn whole only when every edge (a
--    quad's diagonals too) is within tau px; otherwise it is halved across its longest edge in the room, so the
--    cuts never depend on the camera and stay put on the floor while you move. A piece that was halved in the
--    last redraw stays halved until its error is under 0.75 tau (no flicker at the threshold). tau follows the
--    number of pieces (about 1600; 1.5 to 5 px). The pieces are collected before any is drawn: a redraw that would
--    run past the hard cap is collected again with a coarser tau (past 5 px for that redraw alone, up to 10), and
--    only then does the cap stop the halving (the picture gets coarser, but nothing is ever left out).
--  * Pieces that cross the camera's near plane are halved down to 0.05 yd and then clipped exactly at the near
--    plane; nothing is ever dropped. Whole subtrees and nodes outside the view are skipped by their bounding boxes.
--  * Every piece has a key (its prim and its path through the halvings) and keeps its texture from frame to frame,
--    so a frame where the camera moved costs four SetVertexOffset per piece and little else; a frame where it did
--    not move costs nothing. A texture that is no longer needed goes back to its frame's pool, where a new piece of
--    any picture in that frame takes it (past a budget, a frame with none borrows one from another frame).
--  * Mark lines (rings, columns, beams) are put into that same order by running each segment down the tree.
-- Not here yet (later steps of the spec): camera collision, copies of the room over the models, the texture morph
-- and the time-based budget controller.
local _, ns = ...

local Room = { opts = {} }
ns.TrainerRoom = Room

local floor, sqrt, abs, max = math.floor, math.sqrt, math.abs, math.max
local pairs, pcall, type = pairs, pcall, type
local wipe = wipe
-- (Lua 5.1 allows 200 locals in this main chunk: values only read once per redraw or less live in tables, CTL)

---------------------------------------------------------------------------
-- Constants (spec section 3)
---------------------------------------------------------------------------

local MARGIN = 2                  -- px: the frustum is this much bigger than the view
-- The screen-error bound tau and its count controller (spec 5.7, 5.11): tau starts at 2 px and stays within
-- 1.5 .. 5; a piece halved in the last redraw is drawn whole again only under merge * tau; the controller aims at
-- `target` pieces per redraw, nothing is halved past `cap`. State: tau = what the next redraw uses (the controller
-- moves it), used = what the picture on screen was drawn with. selfEvery / selfPx / selfRun: the projection
-- self-check runs every 30th camera move and warns after 10 checks in a row more than 1.5 px off.
-- limit: a redraw that still runs past the cap at max is collected again coarser, up to this (spec 11 says the cap
-- coarsens the nearest pieces only for a frame or two; at max tau cannot rise any more, so it would stay).
-- midCap: midpoints kept from redraw to redraw (spec 3 kept up to 2^18: 16 arrays of that size are tens of MB).
-- texBudget: room textures made before a frame with none free borrows a hidden one from another frame (a safety net:
-- a frame's free textures serve all its pictures, so a session normally stays at 3-4k; render_check's runs, which jump
-- across the room from pose to pose, make up to about 7.8k).
-- epoch: counts the changes of camera, order and room that move mark lines (Room.Line reuses a still frame's).
local CTL = { start = 2.0, min = 1.5, max = 5.0, merge = 0.75, target = 1600, cap = 2800, tau = 2.0, used = 2.0,
              limit = 10.0, midCap = 16384, texBudget = 10000, epoch = 0,
              selfEvery = 30, selfPx = 1.5, selfRun = 10 }
local MAXDEPTH = 18               -- halvings of one prim at most
local MINCLIP2 = 0.05 * 0.05      -- a piece crossing the near plane is halved until its longest edge is under this
local EPS_SIDE = 1e-4             -- a node seen exactly edge-on draws nothing
local LINE_EPS = 0.02             -- yd: mark segments this close to a node's plane lie in it
local KP = 4194304                -- 2^22: piece key = prim * KP + path * 4 + kind (0 piece, 1 second clipped part)
local MIDK = 262144               -- 2^18: midpoint cache key = lo * MIDK + hi (point ids < 2^18)
local TMP0 = MIDK + 16            -- temporary points (near-plane clip points): TMP0 + 1 .., reset every redraw
local LAYERS = { "BACKGROUND", "BORDER", "ARTWORK", "OVERLAY" }
local BLENDS = { [0] = "DISABLE", [1] = "ALPHAKEY", [2] = "BLEND" }
local VUL, VLL = UPPER_LEFT_VERTEX or 1, LOWER_LEFT_VERTEX or 2
local VUR, VLR = UPPER_RIGHT_VERTEX or 3, LOWER_RIGHT_VERTEX or 4

-- Room.opts (spec section 8, UI._RenderOpts): tau (a number fixes the bound and turns the controller off),
-- adaptive (the count controller), adaptiveTime, target, hardCap, morph, copies, collision, siblingQuads, opaque,
-- dilate, camDt. Not used yet (later steps): adaptiveTime, morph, copies, collision, siblingQuads, dilate, camDt.
-- Not in the spec (tests and tuning; unset = CTL's): texBudget, midCap.
do
    local DEFAULTS = { adaptive = true, adaptiveTime = true, target = CTL.target, hardCap = CTL.cap, morph = true,
                       copies = true, collision = true, siblingQuads = false, opaque = true, dilate = 0, camDt = false }
    for k, v in pairs(DEFAULTS) do Room.opts[k] = v end
end

---------------------------------------------------------------------------
-- State. Everything hot is a flat array; nothing is allocated per frame.
---------------------------------------------------------------------------

local view, scene, LVt                    -- the view frame, its ModelScene, the level table (Room.Attach)
local NEAR = 0.5                          -- the scene's near clip (Room.Attach)
local V                                   -- the view's level the frames were put on
local roomFrames = {}                     -- cluster frames by index (kept across rooms; their pools too)
local lineFrame                           -- mark segments that come before every node

-- points: room vertices 1..nV, midpoints nV+1.., temporaries TMP0+1..
local WX, WY, WZ, TU, TV, DU, DV = {}, {}, {}, {}, {}, {}, {}      -- arena position, texture coordinate (shown)
local PS, PR, PU, PD, PX, PY, PQ = {}, {}, {}, {}, {}, {}, {}      -- camera space, screen, sqrt(depth) (PS == gen)
local MA, MB = {}, {}                                              -- a midpoint's edge (nil: a room vertex)
local midOf = {}                                                   -- edge key -> midpoint id

-- BSP nodes
local NA, NB, NC, ND, NFR, NBK = {}, {}, {}, {}, {}, {}            -- plane, front / back child (0: none)
local FP, LP = {}, {}                                              -- first / last prim
local SB, OB = {}, {}                                              -- subtree box, own prims' box (6 per node)
local frameOf, side, sideSign, rankOf, orderNode, pos = {}, {}, {}, {}, {}, {}
local fOrd, fSeen, fNext = {}, {}, {}                              -- per frame: place in the stack
local stN, stP = {}, {}                                            -- traversal stack

-- prims (node by node): a triangle (QD = 0) or a quad, cyclic QA, QB, QC, QD
local QA, QB, QC, QD, QL, QO, QN, QTEX, QPOOL = {}, {}, {}, {}, {}, {}, {}, {}, {}

local live, liveList = {}, {}                                      -- piece key -> texture; the live ones
local splitPrev, splitCur = {}, {}                                 -- piece keys halved in the last / this redraw
local LR = {}                                                      -- the redraw's pieces, 8 numbers each (Leaf)
local LT = {}                                                      -- per piece: its texture from the last redraw
local REL, nRel = {}, 0                                            -- textures given back this redraw (still shown)
local redoOK, aborted = false, false                               -- past the hard cap: collect again coarser

local curMesh, meshOk = nil, false
local nV, nPts, nTmp, nNodes, nPrims, nFrames, nLive = 0, 0, 0, 0, 0, 0, 0
local nLeaves, nClipped, nCapped, gen, stamp1 = 0, 0, 0, 0, 0
local forceOrder, dirty, camMoved, haveBasis, wipeMid = true, true, false, false, false
local camDriven = false                                            -- this redraw is there because the camera moved
local orderValid = false                                           -- pass 1b ran for this mesh
local stats = { redraws = 0, pass1b = 0, redraw = false, moves = 0, selfBad = 0, redone = 0, textures = 0, lent = 0 }

-- for the redraw under way: tau^2 and (merge * tau)^2 (the hysteresis), and the hard cap
local tau2, merge2, hardCap = CTL.tau ^ 2, (CTL.merge * CTL.tau) ^ 2, CTL.cap
local morphOn = false             -- the per-edge texture morph (spec 5.6, step 8); off: shown = true coordinates

-- the camera in the room's own (arena) coordinates, and the screen mapping measured from the scene
local ex, ey, ez, Fx, Fy, Fz = 0, 0, 0, 1, 0, 0
local Rx, Ry, Ux, Uy, Uz = 0, 1, 0, 0, 1
local cx, cy, exx, exy, eyx, eyy = 0, 0, 1, 0, 0, 1
local ox, oy = 0, 0                                                -- the scene's centre (textures hang there)
local cl, cr, cb, ct = 0, 0, 0, 0                                  -- frustum constants (left, right, bottom, top)
local FR = {}                                                      -- the 5 frustum planes in arena space
local camKey = {}                                                  -- the last camera: x y z fx fy fz w h scale

-- mark lines
local MKS, nMarks = {}, 0                                          -- segments drawn this frame (UI._Marks)
local linesChanged = false

local floorCells, TRI                                              -- floor triangles by 8 yd square (FloorZ)

---------------------------------------------------------------------------
-- Preparing a mesh (once per room)
---------------------------------------------------------------------------

-- (The helpers live in a block of their own: the main chunk's 200 locals are for what runs every frame.)
local ComputePools, RoomFrame, Prepare
do
local CAP_NODES, ROOM_FRAMES_MAX = 32, 200
local BLEND_CODE = { DISABLE = 0, ALPHAKEY = 1, BLEND = 2 }

local function PreparePoints(mesh)
    local v = mesh.verts
    nV = floor(#v / 6)
    for i = 1, nV do
        local o = i * 6 - 6
        WX[i], WY[i], WZ[i] = v[o + 1], v[o + 2], v[o + 3]
        TU[i], TV[i], DU[i], DV[i] = v[o + 4], v[o + 5], v[o + 4], v[o + 5]
        PS[i], MA[i], MB[i] = 0, nil, nil
    end
    nPts = nV
    wipe(midOf)
    wipeMid = false
end

-- Does triangle (j1, j2, j3) walk the edge q -> p?
local function Walks(j1, j2, j3, q, p)
    return (j1 == q and j2 == p) or (j2 == q and j3 == p) or (j3 == q and j1 == p)
end

-- The prims, node by node: every triangle alone, or with its quad mate as one quad (a, b, d, c), where the
-- triangle is turned to (a, b, c) with (b, c) the edge it shares with the mate and d the mate's own corner. QO is
-- +1 when the prim's winding agrees with its node's plane normal, -1 when it is the other way round.
local function PreparePrims(mesh)
    local t, nodes, v = mesh.tris, mesh.nodes, mesh.verts
    local pair = (mesh.version == 2) and mesh.pair or nil
    nNodes = floor(#nodes / 8)
    local np, solo = 0, {}
    for k = 1, nNodes do
        local o = k * 8 - 8
        local na, nb, nc = nodes[o + 1], nodes[o + 2], nodes[o + 3]
        NA[k], NB[k], NC[k], ND[k] = na, nb, nc, nodes[o + 4]
        NFR[k], NBK[k] = nodes[o + 5], nodes[o + 6]
        local first = nodes[o + 7]
        local last = first + nodes[o + 8] - 1
        FP[k] = np + 1
        for i = first, last do
            local j = pair and pair[i] or 0
            if j ~= 0 and (j < first or j > last or pair[j] ~= i or solo[i]) then j = 0 end
            if j == 0 or j > i then
                local a, b, c = t[i * 4 - 3], t[i * 4 - 2], t[i * 4 - 1]
                local d = 0
                if j > i then
                    local j1, j2, j3 = t[j * 4 - 3], t[j * 4 - 2], t[j * 4 - 1]
                    local found = true
                    if Walks(j1, j2, j3, b, a) then a, b, c = c, a, b
                    elseif Walks(j1, j2, j3, a, c) then a, b, c = b, c, a
                    elseif not Walks(j1, j2, j3, c, b) then found = false end
                    if found then
                        d = (j1 ~= b and j1 ~= c) and j1 or ((j2 ~= b and j2 ~= c) and j2 or j3)
                    else
                        solo[j] = true                       -- (no shared edge after all: both alone)
                    end
                end
                np = np + 1
                QA[np], QB[np], QN[np], QTEX[np] = a, b, k, t[i * 4]
                if d ~= 0 then
                    QC[np], QD[np] = d, c
                    QL[np] = (v[a * 6] + v[b * 6] + v[c * 6] + v[d * 6]) / 4
                else
                    QC[np], QD[np] = c, 0
                    QL[np] = (v[a * 6] + v[b * 6] + v[c * 6]) / 3
                end
                local ux, uy, uz = WX[b] - WX[a], WY[b] - WY[a], WZ[b] - WZ[a]
                local wx, wy, wz = WX[c] - WX[a], WY[c] - WY[a], WZ[c] - WZ[a]
                local dot = (uy * wz - uz * wy) * na + (uz * wx - ux * wz) * nb + (ux * wy - uy * wx) * nc
                QO[np] = (dot > 1e-9) and 1 or ((dot < -1e-9) and -1 or 0)
            end
        end
        LP[k] = np
    end
    nPrims = np
end

-- Pool key of every prim: texture file * 4 + blend code (opaque WMO materials draw with blending off; with
-- Room.opts.opaque == false as plain textures).
function ComputePools()
    local tex = curMesh.textures
    local bl = (curMesh.version == 2) and curMesh.blend or nil
    local opaque = Room.opts.opaque ~= false
    for p = 1, nPrims do
        local ti = QTEX[p]
        local code = BLEND_CODE[bl and bl[ti] or "DISABLE"] or 0
        if code == 0 and not opaque then code = 2 end
        QPOOL[p] = (tonumber(tex[ti]) or 0) * 4 + code
    end
end

-- Bounding boxes (own prims, whole subtree) and subtree sizes. -> the nodes in pre-order and their sizes, or nil
-- when the tree does not reach every node.
local function PrepareBoxes()
    for k = 1, nNodes do
        local x0, y0, z0, x1, y1, z1 = 1e9, 1e9, 1e9, -1e9, -1e9, -1e9
        for p = FP[k], LP[k] do
            for n = 1, 4 do
                local id = (n == 1 and QA[p]) or (n == 2 and QB[p]) or (n == 3 and QC[p]) or QD[p]
                if id ~= 0 then
                    local x, y, z = WX[id], WY[id], WZ[id]
                    if x < x0 then x0 = x end
                    if x > x1 then x1 = x end
                    if y < y0 then y0 = y end
                    if y > y1 then y1 = y end
                    if z < z0 then z0 = z end
                    if z > z1 then z1 = z end
                end
            end
        end
        local o = k * 6 - 6
        OB[o + 1], OB[o + 2], OB[o + 3], OB[o + 4], OB[o + 5], OB[o + 6] = x0, y0, z0, x1, y1, z1
    end
    local order, size, n, sp = {}, {}, 0, 1
    stN[1] = 1
    while sp > 0 do
        local k = stN[sp]
        sp = sp - 1
        if k < 1 or k > nNodes or size[k] then return nil end    -- a broken tree: the flat fallback
        size[k] = 0
        n = n + 1
        order[n] = k
        if NFR[k] ~= 0 then sp = sp + 1 stN[sp] = NFR[k] end
        if NBK[k] ~= 0 then sp = sp + 1 stN[sp] = NBK[k] end
    end
    if n ~= nNodes then return nil end
    for i = n, 1, -1 do                                          -- children before their parent
        local k = order[i]
        local o = k * 6 - 6
        local x0, y0, z0, x1, y1, z1 = OB[o + 1], OB[o + 2], OB[o + 3], OB[o + 4], OB[o + 5], OB[o + 6]
        local s = 1
        for c = 1, 2 do
            local ch = (c == 1) and NFR[k] or NBK[k]
            if ch ~= 0 then
                local q = ch * 6 - 6
                if SB[q + 1] < x0 then x0 = SB[q + 1] end
                if SB[q + 2] < y0 then y0 = SB[q + 2] end
                if SB[q + 3] < z0 then z0 = SB[q + 3] end
                if SB[q + 4] > x1 then x1 = SB[q + 4] end
                if SB[q + 5] > y1 then y1 = SB[q + 5] end
                if SB[q + 6] > z1 then z1 = SB[q + 6] end
                s = s + size[ch]
            end
        end
        SB[o + 1], SB[o + 2], SB[o + 3], SB[o + 4], SB[o + 5], SB[o + 6] = x0, y0, z0, x1, y1, z1
        size[k] = s
    end
    return order, size
end

-- Cluster frames (spec section 3). In pre-order, a node without a frame whose subtree has at most CAP_NODES
-- nodes gets a frame holding that whole subtree. Every other node (a "top node") joins the frame of a child whose
-- whole subtree is a frame with room left (the smaller one), or gets a frame of its own. Either way a frame's
-- nodes are contiguous in the drawing order: a subtree, or a subtree and its parent. -> false when there are more
-- than ROOM_FRAMES_MAX.
local function BuildClusters(order, size)
    for k = 1, nNodes do frameOf[k] = nil end
    local froot, fcount, fjoined = {}, {}, {}
    local nf, stack = 0, {}
    for i = 1, nNodes do
        local k = order[i]
        if not frameOf[k] and size[k] <= CAP_NODES then
            nf = nf + 1
            froot[nf], fcount[nf], fjoined[nf] = k, size[k], false
            local sp = 1
            stack[1] = k
            while sp > 0 do
                local q = stack[sp]
                sp = sp - 1
                frameOf[q] = nf
                if NFR[q] ~= 0 then sp = sp + 1 stack[sp] = NFR[q] end
                if NBK[q] ~= 0 then sp = sp + 1 stack[sp] = NBK[q] end
            end
        end
    end
    for i = 1, nNodes do
        local k = order[i]
        if not frameOf[k] then
            local best
            for c = 1, 2 do
                local ch = (c == 1) and NFR[k] or NBK[k]
                local f = ch ~= 0 and frameOf[ch]
                if f and froot[f] == ch and fcount[f] < CAP_NODES and not fjoined[f]
                    and (not best or fcount[f] < fcount[best]) then
                    best = f
                end
            end
            if best then
                frameOf[k] = best
                fcount[best], fjoined[best] = fcount[best] + 1, true
            else
                nf = nf + 1
                froot[nf], fcount[nf], fjoined[nf] = 0, 1, true
                frameOf[k] = nf
            end
        end
    end
    nFrames = nf
    return nf <= ROOM_FRAMES_MAX
end

-- The floors (normal at most ~45 degrees from up) by 8 yd squares, for FloorZ.
local function BuildFloorGrid(mesh)
    TRI = mesh.tris
    local cells = {}
    for i = 1, floor(#TRI / 4) do
        local a, b, c = TRI[i * 4 - 3], TRI[i * 4 - 2], TRI[i * 4 - 1]
        local ux, uy, uz = WX[b] - WX[a], WY[b] - WY[a], WZ[b] - WZ[a]
        local wx, wy, wz = WX[c] - WX[a], WY[c] - WY[a], WZ[c] - WZ[a]
        local nx, ny, nz = uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx
        local len = sqrt(nx * nx + ny * ny + nz * nz)
        if len > 0 and nz >= 0.7 * len then
            local x0, x1 = math.min(WX[a], WX[b], WX[c]), math.max(WX[a], WX[b], WX[c])
            local y0, y1 = math.min(WY[a], WY[b], WY[c]), math.max(WY[a], WY[b], WY[c])
            for gx = floor(x0 / 8), floor(x1 / 8) do
                for gy = floor(y0 / 8), floor(y1 / 8) do
                    local key = gx * 1000 + gy
                    local cell = cells[key]
                    if not cell then
                        cell = {}
                        cells[key] = cell
                    end
                    cell[#cell + 1] = i
                end
            end
        end
    end
    floorCells = cells
end

-- free: the frame's unused textures by pool, nfree of them in all (hidden; those given back in a redraw are hidden at
-- its end unless a new piece took them).
function RoomFrame(f)
    local fr = roomFrames[f]
    if not fr then
        fr = CreateFrame("Frame", nil, view)
        fr:SetAllPoints(view)
        fr.free, fr.nfree, fr.lines, fr.lineUsed, fr.lvl, fr.idx, fr.on = {}, 0, {}, 0, -1, f, true
        roomFrames[f] = fr
    end
    return fr
end

function Prepare(mesh)
    if type(mesh.verts) ~= "table" or type(mesh.tris) ~= "table" or type(mesh.nodes) ~= "table"
        or type(mesh.textures) ~= "table" or #mesh.nodes < 8 then
        return false
    end
    PreparePoints(mesh)
    PreparePrims(mesh)
    ComputePools()
    local order, size = PrepareBoxes()
    if not (order and BuildClusters(order, size)) then return false end
    BuildFloorGrid(mesh)
    for f = 1, nFrames do
        local fr = RoomFrame(f)
        if not fr.on then fr:Show() fr.on = true end
    end
    for f = nFrames + 1, #roomFrames do
        local fr = roomFrames[f]
        if fr.on then fr:Hide() fr.on = false end
    end
    for k = 1, nNodes do sideSign[k] = nil end
    -- (the camera is measured again for this room before anything is drawn or a mark is put into its order)
    forceOrder, dirty, orderValid, haveBasis = true, true, false, false
    return true
end
end

---------------------------------------------------------------------------
-- Per frame: the camera (spec 5.3)
---------------------------------------------------------------------------

local function Probe(x, y, z)
    local ok, px, py = pcall(scene.Project3DPointTo2D, scene, x, y, z)
    if ok and type(px) == "number" and type(py) == "number" then return px, py end
end

-- Frustum plane i (4 numbers from FR[i]) from camera-space coefficients: inside when ar*r + au*u + ad*d >= 0,
-- through the eye. Valid behind the camera too.
local function SetPlane(i, ar, au, ad)
    local nx, ny, nz = ar * Rx + au * Ux + ad * Fx, ar * Ry + au * Uy + ad * Fy, au * Uz + ad * Fz
    FR[i], FR[i + 1], FR[i + 2], FR[i + 3] = nx, ny, nz, -(nx * ex + ny * ey + nz * ez)
end

-- An axis-aligned box (6 numbers from B[o + 1]) entirely outside one frustum plane?
local function BoxOut(B, o)
    local x0, y0, z0, x1, y1, z1 = B[o + 1], B[o + 2], B[o + 3], B[o + 4], B[o + 5], B[o + 6]
    for i = 1, 17, 4 do
        local nx, ny, nz = FR[i], FR[i + 1], FR[i + 2]
        if nx * (nx >= 0 and x1 or x0) + ny * (ny >= 0 and y1 or y0) + nz * (nz >= 0 and z1 or z0) + FR[i + 3] < 0 then
            return true
        end
    end
    return false
end

-- The projection self-check (spec 5.3.6): a point 25 yd ahead, 4 right and 2 up, placed with the measured basis and
-- with the scene's own Project3DPointTo2D. If the client's camera were not the pinhole the basis assumes (or lagged
-- a frame behind SetCameraPosition), the room would swim against the models: say so once.
-- s: the scene's effective scale; m: the camera's mirror.
local function SelfCheck(s, m)
    local x, y, z = ex + 25 * Fx + 4 * Rx + 2 * Ux, ey + 25 * Fy + 4 * Ry + 2 * Uy, ez + 25 * Fz + 2 * Uz
    local qx, qy = Probe(x, m * y, z)
    if not qx then return end
    local dx, dy = qx / s - (cx + (4 * exx + 2 * eyx) / 25), qy / s - (cy + (4 * exy + 2 * eyy) / 25)
    local e = sqrt(dx * dx + dy * dy)
    stats.selfCheckPx = e
    stats.selfBad = (e > CTL.selfPx) and (stats.selfBad + 1) or 0
    if stats.selfBad >= CTL.selfRun and not stats.selfWarned then
        stats.selfWarned = true
        if ns.Print then
            ns:Print(("Raid Trainer: the room may not line up with the characters (projection check off by %d px). "
                .. "Please report this."):format(floor(e + 0.5)))
        end
    end
end

-- Is the view's frame level what the frames were put on? (A parent that is moved up or down moves the view.)
local function CheckLevel()
    local lv = view:GetFrameLevel()
    if lv == V then return end
    V = lv
    if lineFrame then lineFrame:SetFrameLevel(V + LVt.lines) end
    if scene then scene:SetFrameLevel(V + LVt.scene) end
    forceOrder, dirty = true, true
end

-- Measure the camera (cam: the trainer's scene camera, x y z fx fy fz mirror). -> false when there is nothing to
-- draw on (no room, no size); true otherwise (when the camera did not move, or cannot be measured, the last
-- picture stays).
function Room.BeginFrame(c)
    if not (meshOk and scene) then return false end
    local w, h = scene:GetWidth() or 0, scene:GetHeight() or 0
    if not (w > 0 and h > 0) then return false end
    local s = scene:GetEffectiveScale() or 1
    if not (s > 0) then s = 1 end
    CheckLevel()
    local x, y, z, fx, fy, fz = c.x, c.y, c.z, c.fx, c.fy, c.fz
    local k = camKey
    if haveBasis and x == k[1] and y == k[2] and z == k[3] and fx == k[4] and fy == k[5] and fz == k[6]
        and w == k[7] and h == k[8] and s == k[9] then
        camMoved, camDriven = dirty, false
        return true
    end
    local flat = sqrt(fx * fx + fy * fy)
    if flat < 1e-4 then
        camMoved, camDriven = false, false
        return true
    end
    -- the screen point straight ahead and what one yard right / up is worth there, measured 10 yd ahead (scene
    -- coordinates: y already mirrored)
    local rx, ry = fy / flat, -fx / flat                               -- right = forward x up
    local ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx            -- up = right x forward
    local ax, ay, az = x + fx * 10, y + fy * 10, z + fz * 10
    local p0x, p0y = Probe(ax, ay, az)
    local p1x, p1y = Probe(ax + rx, ay + ry, az)
    local p2x, p2y = Probe(ax + ux, ay + uy, az + uz)
    if not (p0x and p1x and p2x) then
        camMoved, camDriven = false, false
        return true
    end
    local m = c.mirror or 1
    cx, cy = p0x / s, p0y / s
    exx, exy = (p1x / s - cx) * 10, (p1y / s - cy) * 10
    eyx, eyy = (p2x / s - cx) * 10, (p2y / s - cy) * 10
    ex, ey, ez = x, m * y, z
    Fx, Fy, Fz = fx, m * fy, fz
    Rx, Ry = rx, m * ry
    Ux, Uy, Uz = ux, m * uy, uz
    ox, oy = w / 2, h / 2
    cl, cr, cb, ct = cx + MARGIN, w + MARGIN - cx, cy + MARGIN, h + MARGIN - cy
    SetPlane(1, exx, eyx, cl)
    SetPlane(5, -exx, -eyx, cr)
    SetPlane(9, exy, eyy, cb)
    SetPlane(13, -exy, -eyy, ct)
    FR[17], FR[18], FR[19], FR[20] = Fx, Fy, Fz, -(Fx * ex + Fy * ey + Fz * ez) - NEAR
    k[1], k[2], k[3], k[4], k[5], k[6], k[7], k[8], k[9] = x, y, z, fx, fy, fz, w, h, s
    haveBasis, camMoved, camDriven = true, true, true
    CTL.epoch = CTL.epoch + 1
    stats.moves = stats.moves + 1
    if stats.moves % CTL.selfEvery == 0 then SelfCheck(s, m) end
    return true
end

---------------------------------------------------------------------------
-- Points, culling, pieces (spec 5.6 - 5.9)
---------------------------------------------------------------------------

-- Camera space, screen position and sqrt(depth) of a point, once per redraw and only for the points of pieces that
-- are looked at (spec 5.6; the texture morph of midpoints is step 8: until then a midpoint shows its true
-- texture coordinate).
local function Prep(id)
    if PS[id] == gen then return end
    PS[id] = gen
    local dx, dy, dz = WX[id] - ex, WY[id] - ey, WZ[id] - ez
    local d = dx * Fx + dy * Fy + dz * Fz
    local r, u = dx * Rx + dy * Ry, dx * Ux + dy * Uy + dz * Uz
    PR[id], PU[id], PD[id] = r, u, d
    if d > 1e-6 then
        PX[id], PY[id], PQ[id] = cx + (r * exx + u * eyx) / d, cy + (r * exy + u * eyy) / d, sqrt(d)
    end
end

-- (Out3 / Out4, the test whether a piece is out of view, are written out in RefineTri / RefineQuad: all corners
-- behind the near plane, or all outside one side of the view, tested in camera space so that it holds for
-- corners behind the camera too.)

-- Squared length in the room: the same every frame, bit for bit (so the cuts never depend on the camera).
local function W2(a, b)
    local dx, dy, dz = WX[a] - WX[b], WY[a] - WY[b], WZ[a] - WZ[b]
    return dx * dx + dy * dy + dz * dz
end

-- The midpoint of edge (a, b): one point per edge, kept from frame to frame (Pass2 empties the cache once it holds
-- CTL.midCap midpoints; keys are paths, so no texture minds). The key lo * MIDK + hi is unique only while both ids
-- are under MIDK: an edge with a temporary end (the cache ran full inside one redraw) gets a temporary of its own.
local function Mid(a, b)
    if a > b then a, b = b, a end
    local id
    if b < TMP0 then
        local k = a * MIDK + b
        id = midOf[k]
        if id then return id end
        if nPts < MIDK - 16 then
            nPts = nPts + 1
            id = nPts
            midOf[k] = id
        end
    end
    if not id then                               -- full: a temporary now, the cache is emptied at the next redraw
        wipeMid = true
        nTmp = nTmp + 1
        id = TMP0 + nTmp
    end
    WX[id], WY[id], WZ[id] = (WX[a] + WX[b]) * 0.5, (WY[a] + WY[b]) * 0.5, (WZ[a] + WZ[b]) * 0.5
    local u, v = (TU[a] + TU[b]) * 0.5, (TV[a] + TV[b]) * 0.5
    TU[id], TV[id], DU[id], DV[id] = u, v, u, v
    MA[id], MB[id] = a, b
    PS[id] = 0
    return id
end

-- One free texture of frame fr (any pool), or nil.
local function TakeFree(fr)
    for _, list in pairs(fr.free) do
        local n = #list
        if n > 0 then
            local tx = list[n]
            list[n] = nil
            fr.nfree = fr.nfree - 1
            return tx
        end
    end
end

-- A texture of frame f for pool (texture file * 4 + blend): a free one of that pool (the ones given back this
-- redraw come first: they are still shown), else a free one of the frame with another picture (SetTexture), else
-- a new one (spec 4.3). Textures never leave their frame (spec 6), so the frames' free ones add up over a long
-- session: once CTL.texBudget textures exist, a frame that has none free borrows a hidden one from the frame
-- with the most free ones (SetParent, instead of making one).
local function Acquire(f, pool)
    local fr = roomFrames[f]
    local list = fr.free[pool]
    local n = list and #list or 0
    if n > 0 then
        local tx = list[n]
        list[n] = nil
        fr.nfree = fr.nfree - 1
        return tx
    end
    local tx = fr.nfree > 0 and TakeFree(fr)
    if not tx and stats.textures >= (tonumber(Room.opts.texBudget) or CTL.texBudget) then
        local d = roomFrames[CTL.donor or 0]
        if not (d and d.nfree > 0) then
            d = nil
            local most = 0
            for i = 1, #roomFrames do
                local q = roomFrames[i]
                if q.nfree > most then d, most = q, q.nfree end
            end
            CTL.donor = d and d.idx
        end
        tx = d and TakeFree(d)
        if tx then
            tx:SetParent(fr)
            tx.frame = f
            stats.lent = stats.lent + 1
        end
    end
    if tx then
        local was = tx.pool
        if was ~= pool then
            if floor(was / 4) ~= floor(pool / 4) then tx:SetTexture(floor(pool / 4), "REPEAT", "REPEAT") end
            if was % 4 ~= pool % 4 then tx:SetBlendMode(BLENDS[pool % 4]) end
            tx.pool = pool
        end
        return tx
    end
    stats.textures = stats.textures + 1
    tx = fr:CreateTexture(nil, "BACKGROUND")
    tx:SetSize(1, 1)
    tx:SetPoint("CENTER", scene, "CENTER", 0, 0)      -- the 1 x 1 base sits mid-view: no cull / clip test fails on it
    if tx.SetSnapToPixelGrid then tx:SetSnapToPixelGrid(false) end
    if tx.SetTexelSnappingBias then tx:SetTexelSnappingBias(0) end
    tx:SetTexture(floor(pool / 4), "REPEAT", "REPEAT")
    tx:SetBlendMode(BLENDS[pool % 4])
    tx.frame, tx.pool, tx.shown = f, pool, true
    return tx
end

-- Did a corner's texture coordinate move by more than 0.3 px worth of texture since it was sent? (spec 5.9.2)
local function UVMoved(tx, ul, ll, ur, lr)
    local du = max(abs(DU[ul] - tx.u1), abs(DV[ul] - tx.v1), abs(DU[ll] - tx.u2), abs(DV[ll] - tx.v2),
                   abs(DU[ur] - tx.u3), abs(DV[ur] - tx.v3), abs(DU[lr] - tx.u4), abs(DV[lr] - tx.v4))
    if du <= 1e-6 then return false end
    local best, buv = -1, 0
    for e = 1, 4 do
        local a = (e == 1 and ul) or (e == 2 and ll) or (e == 3 and lr) or ur
        local b = (e == 1 and ll) or (e == 2 and lr) or (e == 3 and ur) or ul
        local sx, sy = PX[a] - PX[b], PY[a] - PY[b]
        local L = sx * sx + sy * sy
        if L > best then
            local su, sv = DU[a] - DU[b], DV[a] - DV[b]
            best, buv = L, su * su + sv * sv
        end
    end
    if buv < 1e-12 then return true end
    return du * sqrt(best / buv) > 0.3
end

-- One piece on screen (spec 5.9.1): n = 3 (c1, c2, c3; c4 == c3) or 4 (cyclic c1..c4). UL = c1, LL = c2,
-- UR = c4, LR = c3: a triangle's UR and LR are the same corner, a quad's diagonal LL - UR is c2 - c4.
-- tx: the piece's texture from the last redraw (false: it gets one).
local function Emit(p, key, n, c1, c2, c3, c4, clipped, tx)
    local k = QN[p]
    if not tx then
        tx = Acquire(frameOf[k], QPOOL[p])
        live[key] = tx
        nLive = nLive + 1
        liveList[nLive] = tx
        tx.key, tx.uvOk = key, false
        local L = QL[p]
        if tx.light ~= L then
            tx:SetVertexColor(L, L, L)
            tx.light = L
        end
    end
    tx.gen = gen
    -- (a key always has the same corners, so without the morph their texture coordinates never change; a piece cut
    -- at the near plane has cut corners, and its key shows the whole piece again once it is clear of the plane: so a
    -- cut send never counts as the whole piece's)
    if clipped or not tx.uvOk
        or (morphOn and (c1 > nV or c2 > nV or c3 > nV or c4 > nV) and UVMoved(tx, c1, c2, c4, c3)) then
        local u1, v1, u2, v2, u3, v3, u4, v4 = DU[c1], DV[c1], DU[c2], DV[c2], DU[c4], DV[c4], DU[c3], DV[c3]
        tx:SetTexCoord(u1, v1, u2, v2, u3, v3, u4, v4)
        tx.u1, tx.v1, tx.u2, tx.v2, tx.u3, tx.v3, tx.u4, tx.v4 = u1, v1, u2, v2, u3, v3, u4, v4
        tx.uvOk = not clipped
    end
    local pp = pos[k]
    if tx.pos ~= pp then
        tx:SetDrawLayer(LAYERS[floor(pp / 16) + 1], pp % 16 - 8)
        tx.pos = pp
    end
    tx:SetVertexOffset(VUL, PX[c1] - ox + 0.5, PY[c1] - oy - 0.5)
    tx:SetVertexOffset(VLL, PX[c2] - ox + 0.5, PY[c2] - oy + 0.5)
    tx:SetVertexOffset(VUR, PX[c4] - ox - 0.5, PY[c4] - oy - 0.5)
    tx:SetVertexOffset(VLR, PX[c3] - ox - 0.5, PY[c3] - oy + 0.5)
    if not tx.shown then
        tx:Show()
        tx.shown = true
    end
end

-- The point where segment i -> j meets the near plane (exactly: linear in the room and in camera space).
local function ClipPoint(i, j)
    local di = PD[i]
    local t = (NEAR - di) / (PD[j] - di)
    nTmp = nTmp + 1
    local id = TMP0 + nTmp
    WX[id] = WX[i] + (WX[j] - WX[i]) * t
    WY[id] = WY[i] + (WY[j] - WY[i]) * t
    WZ[id] = WZ[i] + (WZ[j] - WZ[i]) * t
    local r, u = PR[i] + (PR[j] - PR[i]) * t, PU[i] + (PU[j] - PU[i]) * t
    PR[id], PU[id], PD[id] = r, u, NEAR
    DU[id], DV[id] = DU[i] + (DU[j] - DU[i]) * t, DV[i] + (DV[j] - DV[i]) * t
    PX[id], PY[id] = cx + (r * exx + u * eyx) / NEAR, cy + (r * exy + u * eyy) / NEAR
    PS[id] = gen
    return id
end

-- A piece to draw (a leaf of the halvings): recorded in LR (8 numbers per leaf: prim, key, corners 3 or 4, the
-- four corner points, clipped), drawn once the whole redraw is known to fit (Pass2). A redraw whose tau is still
-- the controller's to move and that runs past the hard cap stops at once (aborted) and is done again coarser.
local function Leaf(p, key, n, c1, c2, c3, c4, clipped)
    local i = nLeaves + 1
    nLeaves = i
    if i > hardCap and redoOK then
        aborted = true
        return
    end
    local o = i * 8 - 8
    LR[o + 1], LR[o + 2], LR[o + 3], LR[o + 4], LR[o + 5], LR[o + 6], LR[o + 7], LR[o + 8] =
        p, key, n, c1, c2, c3, c4, clipped
end

-- A piece that crosses the near plane, cut there (Sutherland-Hodgman, spec 5.8): 3 or 4 corners are one texture;
-- 5 (a quad) are two, the quad (v1, v2, v3, v4) and the triangle (v1, v4, v5) with the next key.
local ClipLeaf
do
local CI, CO = {}, {}
function ClipLeaf(p, key, n, a, b, c, d)
    CI[1], CI[2], CI[3], CI[4] = a, b, c, d
    local m = 0
    for i = 1, n do
        local P = CI[i]
        local Q = CI[(i < n) and (i + 1) or 1]
        local pin, qin = PD[P] >= NEAR, PD[Q] >= NEAR
        if pin then
            m = m + 1
            CO[m] = P
        end
        if pin ~= qin then
            m = m + 1
            CO[m] = ClipPoint(P, Q)
        end
    end
    if m < 3 then return end
    nClipped = nClipped + 1
    if m == 3 then
        Leaf(p, key, 3, CO[1], CO[2], CO[3], CO[3], true)
    elseif m == 4 then
        Leaf(p, key, 4, CO[1], CO[2], CO[3], CO[4], true)
    else
        local v1, v4, v5 = CO[1], CO[4], CO[5]
        Leaf(p, key, 4, v1, CO[2], CO[3], v4, true)
        Leaf(p, key + 1, 3, v1, v4, v5, v5, true)
    end
end
end

-- A triangle piece (spec 5.7): drawn whole when its affine error is within tau on every edge (under MERGE * tau
-- when it was halved in the last redraw), else halved across its longest edge in the room: (P, M, R) and (M, Q, R)
-- keep the winding. A piece crossing the near plane is halved until it is small, then clipped there. path = the
-- halvings so far (root 1, children 2p, 2p+1); lev = how many. Past the hard cap (or MAXDEPTH) a piece in front
-- of the near plane is drawn as it is.
-- The edge test is exact (spec A.1): an edge L px long between depths d1 and d2 shows its picture at most
-- L |sqrt d1 - sqrt d2| / (sqrt d1 + sqrt d2) px from where it belongs, and no point inside a piece is further off
-- than on its worst edge. Compared squared, written out where it runs (every piece of every redraw): an edge from a
-- to b (both in front of the near plane) is over t2 = tau^2 when
--   ((PX[a] - PX[b])^2 + (PY[a] - PY[b])^2) (PQ[a] - PQ[b])^2 > t2 (PQ[a] + PQ[b])^2.
local RefineTri, RefineQuad
RefineTri = function(p, path, a, b, c, lev)
    if aborted then return end
    local g = gen
    if PS[a] ~= g then Prep(a) end
    if PS[b] ~= g then Prep(b) end
    if PS[c] ~= g then Prep(c) end
    -- out of view (Out3, written out): every corner behind the near plane or outside one side of the view
    local da, db, dc = PD[a], PD[b], PD[c]
    if da < NEAR and db < NEAR and dc < NEAR then return end
    local ra, ua, rb, ub, rc, uc = PR[a], PU[a], PR[b], PU[b], PR[c], PU[c]
    local la, lb, lc = ra * exx + ua * eyx, rb * exx + ub * eyx, rc * exx + uc * eyx
    if (la + cl * da < 0 and lb + cl * db < 0 and lc + cl * dc < 0) or (cr * da < la and cr * db < lb and cr * dc < lc)
    then return end
    la, lb, lc = ra * exy + ua * eyy, rb * exy + ub * eyy, rc * exy + uc * eyy
    if (la + cb * da < 0 and lb + cb * db < 0 and lc + cb * dc < 0) or (ct * da < la and ct * db < lb and ct * dc < lc)
    then return end
    local key = p * KP + path * 4
    local crossing = da < NEAR or db < NEAR or dc < NEAR
    local split = false
    if lev < MAXDEPTH then
        if crossing then
            split = W2(a, b) > MINCLIP2 or W2(b, c) > MINCLIP2 or W2(c, a) > MINCLIP2
        else
            local room = nLeaves < hardCap
            local t2 = (room and splitPrev[key]) and merge2 or tau2
            local xa, ya, qa, xb, yb, qb, xc, yc, qc = PX[a], PY[a], PQ[a], PX[b], PY[b], PQ[b], PX[c], PY[c], PQ[c]
            local dx, dy, ds, ss = xa - xb, ya - yb, qa - qb, qa + qb                   -- a - b
            local over = (dx * dx + dy * dy) * ds * ds > t2 * ss * ss
            if not over then
                dx, dy, ds, ss = xb - xc, yb - yc, qb - qc, qb + qc                     -- b - c
                over = (dx * dx + dy * dy) * ds * ds > t2 * ss * ss
            end
            if not over then
                dx, dy, ds, ss = xc - xa, yc - ya, qc - qa, qc + qa                     -- c - a
                over = (dx * dx + dy * dy) * ds * ds > t2 * ss * ss
            end
            if room then
                split = over
            elseif over then
                nCapped = nCapped + 1                                      -- (would have been halved)
            end
        end
    end
    if split then
        splitCur[key] = true
        -- across the longest edge in the room (lengths that are the same every frame, bit for bit)
        local x1, y1, z1, x2, y2, z2, x3, y3, z3 = WX[a], WY[a], WZ[a], WX[b], WY[b], WZ[b], WX[c], WY[c], WZ[c]
        local u, v, w = x1 - x2, y1 - y2, z1 - z2
        local lab = u * u + v * v + w * w
        u, v, w = x2 - x3, y2 - y3, z2 - z3
        local lbc = u * u + v * v + w * w
        u, v, w = x3 - x1, y3 - y1, z3 - z1
        local lca = u * u + v * v + w * w
        local P, Q, R
        if lab >= lbc and lab >= lca then P, Q, R = a, b, c
        elseif lbc >= lca then P, Q, R = b, c, a
        else P, Q, R = c, a, b end
        local M = Mid(P, Q)
        RefineTri(p, path * 2, P, M, R, lev + 1)
        RefineTri(p, path * 2 + 1, M, Q, R, lev + 1)
    elseif crossing then
        ClipLeaf(p, key, 3, a, b, c, nil)
    else
        Leaf(p, key, 3, a, b, c, c, false)
    end
end

-- A quad piece (cyclic a, b, c, d): its four edges and both diagonals must be within the bound (whichever diagonal
-- the client splits it along); else it is halved across its two longer opposite edges (two quads, same winding).
RefineQuad = function(p, path, a, b, c, d, lev)
    if aborted then return end
    local g = gen
    if PS[a] ~= g then Prep(a) end
    if PS[b] ~= g then Prep(b) end
    if PS[c] ~= g then Prep(c) end
    if PS[d] ~= g then Prep(d) end
    -- out of view (Out4, written out)
    local da, db, dc, dd = PD[a], PD[b], PD[c], PD[d]
    if da < NEAR and db < NEAR and dc < NEAR and dd < NEAR then return end
    local ra, ua, rb, ub, rc, uc, rd, ud = PR[a], PU[a], PR[b], PU[b], PR[c], PU[c], PR[d], PU[d]
    local la, lb, lc, ld = ra * exx + ua * eyx, rb * exx + ub * eyx, rc * exx + uc * eyx, rd * exx + ud * eyx
    if (la + cl * da < 0 and lb + cl * db < 0 and lc + cl * dc < 0 and ld + cl * dd < 0)
        or (cr * da < la and cr * db < lb and cr * dc < lc and cr * dd < ld) then return end
    la, lb, lc, ld = ra * exy + ua * eyy, rb * exy + ub * eyy, rc * exy + uc * eyy, rd * exy + ud * eyy
    if (la + cb * da < 0 and lb + cb * db < 0 and lc + cb * dc < 0 and ld + cb * dd < 0)
        or (ct * da < la and ct * db < lb and ct * dc < lc and ct * dd < ld) then return end
    local key = p * KP + path * 4
    local crossing = da < NEAR or db < NEAR or dc < NEAR or dd < NEAR
    local split = false
    if lev < MAXDEPTH then
        if crossing then
            split = W2(a, b) > MINCLIP2 or W2(b, c) > MINCLIP2 or W2(c, d) > MINCLIP2 or W2(d, a) > MINCLIP2
        else
            local room = nLeaves < hardCap
            local t2 = (room and splitPrev[key]) and merge2 or tau2
            local xa, ya, qa, xb, yb, qb = PX[a], PY[a], PQ[a], PX[b], PY[b], PQ[b]
            local xc, yc, qc, xd, yd, qd = PX[c], PY[c], PQ[c], PX[d], PY[d], PQ[d]
            local dx, dy, ds, ss = xa - xb, ya - yb, qa - qb, qa + qb                   -- a - b
            local over = (dx * dx + dy * dy) * ds * ds > t2 * ss * ss
            if not over then
                dx, dy, ds, ss = xb - xc, yb - yc, qb - qc, qb + qc                     -- b - c
                over = (dx * dx + dy * dy) * ds * ds > t2 * ss * ss
            end
            if not over then
                dx, dy, ds, ss = xc - xd, yc - yd, qc - qd, qc + qd                     -- c - d
                over = (dx * dx + dy * dy) * ds * ds > t2 * ss * ss
            end
            if not over then
                dx, dy, ds, ss = xd - xa, yd - ya, qd - qa, qd + qa                     -- d - a
                over = (dx * dx + dy * dy) * ds * ds > t2 * ss * ss
            end
            if not over then
                dx, dy, ds, ss = xa - xc, ya - yc, qa - qc, qa + qc                     -- diagonal a - c
                over = (dx * dx + dy * dy) * ds * ds > t2 * ss * ss
            end
            if not over then
                dx, dy, ds, ss = xb - xd, yb - yd, qb - qd, qb + qd                     -- diagonal b - d
                over = (dx * dx + dy * dy) * ds * ds > t2 * ss * ss
            end
            if room then
                split = over
            elseif over then
                nCapped = nCapped + 1
            end
        end
    end
    if split then
        splitCur[key] = true
        -- across the two longer opposite edges (ab + cd against bc + da, room lengths)
        local x1, y1, z1, x2, y2, z2 = WX[a], WY[a], WZ[a], WX[b], WY[b], WZ[b]
        local x3, y3, z3, x4, y4, z4 = WX[c], WY[c], WZ[c], WX[d], WY[d], WZ[d]
        local u, v, w = x1 - x2, y1 - y2, z1 - z2
        local s1 = u * u + v * v + w * w
        u, v, w = x3 - x4, y3 - y4, z3 - z4
        s1 = s1 + (u * u + v * v + w * w)
        u, v, w = x2 - x3, y2 - y3, z2 - z3
        local s2 = u * u + v * v + w * w
        u, v, w = x4 - x1, y4 - y1, z4 - z1
        s2 = s2 + (u * u + v * v + w * w)
        if s1 >= s2 then
            local m1, m2 = Mid(a, b), Mid(c, d)
            RefineQuad(p, path * 2, a, m1, m2, d, lev + 1)
            RefineQuad(p, path * 2 + 1, m1, b, c, m2, lev + 1)
        else
            local m1, m2 = Mid(b, c), Mid(d, a)
            RefineQuad(p, path * 2, a, b, m1, m2, lev + 1)
            RefineQuad(p, path * 2 + 1, m2, m1, c, d, lev + 1)
        end
    elseif crossing then
        ClipLeaf(p, key, 4, a, b, c, d)
    else
        Leaf(p, key, 4, a, b, c, d, false)
    end
end

-- A texture back into its frame's pool.
local function Free(tx)
    local fr = roomFrames[tx.frame]
    local free = fr.free
    local list = free[tx.pool]
    if not list then
        list = {}
        free[tx.pool] = list
    end
    list[#list + 1] = tx
    fr.nfree = fr.nfree + 1
end

-- Pieces not drawn this redraw go back to their frame's pool (spec 5.10), before the new pieces are drawn but
-- still shown: a new piece of the same frame takes one as it is (no Hide and Show of one texture in a frame, and
-- no new texture while the camera turns); HideReleased hides the rest afterwards.
local function Release()
    local j, g = 1, gen
    while j <= nLive do
        local tx = liveList[j]
        if tx.gen ~= g then
            live[tx.key] = nil
            Free(tx)
            nRel = nRel + 1
            REL[nRel] = tx
            liveList[j] = liveList[nLive]
            liveList[nLive] = nil
            nLive = nLive - 1
        else
            j = j + 1
        end
    end
end

local function HideReleased()
    local g = gen
    for i = 1, nRel do
        local tx = REL[i]
        REL[i] = false
        if tx.gen ~= g and tx.shown then
            tx:Hide()
            tx.shown = false
        end
    end
    nRel = 0
end

---------------------------------------------------------------------------
-- The two passes (spec 5.4, 5.5)
---------------------------------------------------------------------------

-- Which side of every node the camera is on; when any side flipped, the whole order again: every node's rank,
-- its place in its frame, and every frame's level (never culled, so places never depend on what is in view).
local function Pass1()
    local changed = forceOrder
    for k = 1, nNodes do
        local s = NA[k] * ex + NB[k] * ey + NC[k] * ez + ND[k]
        side[k] = s
        local sg = s > 0
        if sg ~= sideSign[k] then
            sideSign[k] = sg
            changed = true
        end
    end
    if not changed then return end
    forceOrder, orderValid = false, true
    stamp1 = stamp1 + 1
    stats.pass1b = stats.pass1b + 1
    local r, nfo, sp = 0, 0, 1
    stN[1], stP[1] = 1, 0
    while sp > 0 do
        local k, ph = stN[sp], stP[sp]
        if ph == 0 then
            stP[sp] = 1
            local far = sideSign[k] and NBK[k] or NFR[k]              -- the side the camera is not on
            if far ~= 0 then
                sp = sp + 1
                stN[sp], stP[sp] = far, 0
            end
        elseif ph == 1 then
            stP[sp] = 2
            orderNode[r], rankOf[k] = k, r
            r = r + 1
            local f = frameOf[k]
            if fSeen[f] ~= stamp1 then
                fSeen[f] = stamp1
                nfo = nfo + 1
                fOrd[f], fNext[f] = nfo, 0
            end
            pos[k] = 2 * fNext[f]
            fNext[f] = fNext[f] + 1
            local near = sideSign[k] and NFR[k] or NBK[k]
            if near ~= 0 then
                sp = sp + 1
                stN[sp], stP[sp] = near, 0
            end
        else
            sp = sp - 1
        end
    end
    local base = V + LVt.room0 - 1
    for f = 1, nFrames do
        local lvl = base + fOrd[f]
        local fr = roomFrames[f]
        if fr.lvl ~= lvl then
            fr:SetFrameLevel(lvl)
            fr.lvl = lvl
        end
    end
end

-- The same order again, skipping what is out of view: every visible prim that faces the camera, cut into the
-- pieces tau asks for (recorded in LR, not drawn yet). Stops early when the redraw was aborted (Leaf).
local function Collect()
    local sp = 1
    stN[1], stP[1] = 1, 0
    while sp > 0 and not aborted do
        local k, ph = stN[sp], stP[sp]
        if ph == 0 then
            if BoxOut(SB, k * 6 - 6) then
                sp = sp - 1                                           -- the whole subtree is out of view
            else
                stP[sp] = 1
                local far = sideSign[k] and NBK[k] or NFR[k]
                if far ~= 0 then
                    sp = sp + 1
                    stN[sp], stP[sp] = far, 0
                end
            end
        elseif ph == 1 then
            stP[sp] = 2
            local s = side[k]
            if (s > EPS_SIDE or s < -EPS_SIDE) and FP[k] <= LP[k] and not BoxOut(OB, k * 6 - 6) then
                local want = (s > 0) and 1 or -1                      -- prims facing the camera
                for p = FP[k], LP[k] do
                    if QO[p] == want then
                        local d = QD[p]
                        if d == 0 then RefineTri(p, 1, QA[p], QB[p], QC[p], 0)
                        else RefineQuad(p, 1, QA[p], QB[p], QC[p], d, 0) end
                    end
                end
            end
            local near = sideSign[k] and NFR[k] or NBK[k]
            if near ~= 0 then
                sp = sp + 1
                stN[sp], stP[sp] = near, 0
            end
        else
            sp = sp - 1
        end
    end
end

-- Pass 2: collect the pieces, then draw them. When tau is the controller's (not fixed), a redraw that runs past the
-- hard cap is not drawn coarse (the nearest geometry would go unhalved, many px off): it is collected again at
-- 1.25 tau, as often as needed (spec 11's order: tau rises to 5 px first, the cap applies only after that). At 5 px
-- the controller's tau stops, but such a redraw is still collected again (up to CTL.limit) rather than leaving its
-- last, nearest pieces whole: the whole picture coarsens a little instead. Nothing is drawn before the pieces are
-- known, so a second collection costs no widget calls.
local function Pass2()
    gen = gen + 1
    local o, C = Room.opts, CTL
    if wipeMid or nPts - nV > (tonumber(o.midCap) or C.midCap) then   -- (the midpoints cache stays small)
        wipe(midOf)
        nPts, wipeMid = nV, false
    end
    splitPrev, splitCur = splitCur, splitPrev                         -- (the halvings of the last redraw)
    local fixed = type(o.tau) == "number" and o.tau > 0
    if fixed then C.tau = o.tau end                                    -- a fixed bound (render_check, tests)
    hardCap = tonumber(o.hardCap) or C.cap
    stats.redone = 0
    -- The hysteresis band (halved pieces merge only under merge * tau) holds tau still against a camera that moves.
    -- In the redraw right after tau rose it starts again from the new tau: a piece halved at the old bound is over
    -- that old bound, which is under merge * new tau for any rise below 1 / merge, so it would never merge and the
    -- controller's rise would buy nothing for frames.
    local lastTau, t = C.used, C.tau
    local adaptive = not fixed and o.adaptive ~= false
    while true do
        wipe(splitCur)
        nLeaves, nClipped, nCapped, nTmp = 0, 0, 0, 0
        redoOK, aborted = adaptive and t < C.limit, false
        C.used, tau2 = t, t * t
        merge2 = (t > lastTau) and tau2 or (C.merge * t) ^ 2
        Collect()
        if not aborted then break end
        t = math.min(C.limit, t * 1.25)
        C.tau = math.min(C.max, t)
        stats.redone = stats.redone + 1
    end
    redoOK = false
    local g = gen
    for i = 1, nLeaves do                                              -- pieces drawn again keep their texture
        local tx = live[LR[i * 8 - 6]]
        LT[i] = tx or false
        if tx then tx.gen = g end
    end
    Release()
    for i = 1, nLeaves do
        local q = i * 8 - 8
        Emit(LR[q + 1], LR[q + 2], LR[q + 3], LR[q + 4], LR[q + 5], LR[q + 6], LR[q + 7], LR[q + 8], LT[i])
    end
    HideReleased()
end

-- Draw the room for the camera BeginFrame measured. Returns at once when it did not move (and nothing was
-- invalidated). -> true when it redrew.
-- Then the count controller (spec 5.11), after a redraw the camera's motion caused: tau rises when the pieces run
-- over the target and sinks slowly when there are few. It rises by the ratio it is over (between the spec's 1.08
-- and 1.25, so a turn from a bare wall to the whole hall is back within the target in a few frames, not ten), by
-- 1.25 near the hard cap. A fixed tau (opts.tau) or opts.adaptive == false turns it off. tau changes only here and
-- in Pass2, so a camera that stands still never redraws.
function Room.DrawRoom()
    stats.redraw = false
    if not (meshOk and haveBasis and camMoved) then return false end
    CTL.epoch = CTL.epoch + 1
    Pass1()
    Pass2()
    local o, C = Room.opts, CTL
    if camDriven and type(o.tau) ~= "number" and o.adaptive ~= false then
        local target, t = tonumber(o.target) or C.target, C.tau
        if nLeaves > 0.95 * hardCap then
            t = t * 1.25
        elseif nLeaves > 1.1 * target then
            t = t * math.min(1.25, max(1.08, nLeaves / (1.1 * target)))
        elseif nLeaves < 0.8 * target then
            t = t * 0.97
        end
        C.tau = math.min(C.max, max(C.min, t))
    end
    dirty, camMoved, camDriven = false, false, false
    stats.redraws = stats.redraws + 1
    stats.redraw = true
    return true
end

---------------------------------------------------------------------------
-- Mark lines, put into the room's order (spec 5.12)
---------------------------------------------------------------------------

local function HideLines(fr, from)
    local ls = fr.lines
    for i = from, #ls do
        local l = ls[i]
        if l.shown then
            l:Hide()
            l.shown = false
            linesChanged = true
        end
    end
end

-- (In a block of its own, like Prepare's helpers.) A camera that stands still sees the same marks every frame:
-- Room.Line then finds each segment as it was in the last frame (same ends, colour and thickness, and every segment
-- before it the same too) and takes its lines again as they stand (no cut, no walk down the tree, no setter).
-- SI: per segment its 11 inputs; SPS / SPN: its first placement and how many; SMK: 1 when it went into MKS;
-- PF: per placement the frame its line is in. CTL.epoch counts what moves lines (camera, order, room).
do
local LS = {}                                                      -- insertion stack: node + 6 coordinates
local SI, SPS, SPN, SMK, PF = {}, {}, {}, {}, {}
local nSeg, nSegLast, nPl, reuse, passEpoch = 0, 0, 0, false, -1

local function NewLine(fr, i)
    local l = fr:CreateLine(nil, "BACKGROUND")
    if l.SetSnapToPixelGrid then l:SetSnapToPixelGrid(false) end
    if l.SetTexelSnappingBias then l:SetTexelSnappingBias(0) end
    l.shown = true
    fr.lines[i] = l
    return l
end

-- One placed segment: the next line of frame fr's pool at place p, from a to b (arena, in front of the camera).
local function PlaceSeg(fr, p, ax, ay, az, bx, by, bz, r, g, b, a, thick)
    local dx, dy, dz = ax - ex, ay - ey, az - ez
    local d = dx * Fx + dy * Fy + dz * Fz
    local rr, uu = dx * Rx + dy * Ry, dx * Ux + dy * Uy + dz * Uz
    local x1, y1 = cx + (rr * exx + uu * eyx) / d, cy + (rr * exy + uu * eyy) / d
    dx, dy, dz = bx - ex, by - ey, bz - ez
    d = dx * Fx + dy * Fy + dz * Fz
    rr, uu = dx * Rx + dy * Ry, dx * Ux + dy * Uy + dz * Uz
    local x2, y2 = cx + (rr * exx + uu * eyx) / d, cy + (rr * exy + uu * eyy) / d
    local i = fr.lineUsed + 1
    fr.lineUsed = i
    nPl = nPl + 1
    PF[nPl] = fr
    local l = fr.lines[i] or NewLine(fr, i)
    if l.pos ~= p then
        l:SetDrawLayer(LAYERS[floor(p / 16) + 1], p % 16 - 8)
        l.pos, linesChanged = p, true
    end
    if l.thick ~= thick then
        l:SetThickness(thick)
        l.thick, linesChanged = thick, true
    end
    if l.cr ~= r or l.cg ~= g or l.cb ~= b or l.ca ~= a then
        l:SetColorTexture(r, g, b, a)
        l.cr, l.cg, l.cb, l.ca, linesChanged = r, g, b, a, true
    end
    if not l.x1 or abs(l.x1 - x1) > 0.01 or abs(l.y1 - y1) > 0.01 then
        l:SetStartPoint("BOTTOMLEFT", scene, x1, y1)
        l.x1, l.y1, linesChanged = x1, y1, true
    end
    if not l.x2 or abs(l.x2 - x2) > 0.01 or abs(l.y2 - y2) > 0.01 then
        l:SetEndPoint("BOTTOMLEFT", scene, x2, y2)
        l.x2, l.y2, linesChanged = x2, y2, true
    end
    if not l.shown then
        l:Show()
        l.shown, linesChanged = true, true
    end
end

function Room.BeginLines()
    nMarks, nSeg, nPl = 0, 0, 0
    reuse = passEpoch == CTL.epoch
    for f = 1, nFrames do roomFrames[f].lineUsed = 0 end
    if lineFrame then lineFrame.lineUsed = 0 end
end

function Room.EndLines()
    for f = 1, #roomFrames do
        local fr = roomFrames[f]
        HideLines(fr, (f <= nFrames) and (fr.lineUsed + 1) or 1)
    end
    if lineFrame then HideLines(lineFrame, lineFrame.lineUsed + 1) end
    nSegLast, passEpoch = nSeg, CTL.epoch
end

-- A mark segment (arena coordinates; colour; thickness): cut at the near plane, then run down the BSP tree. A
-- piece that straddles a node's plane is cut there; a piece on the camera's side of a node goes after it (into
-- the near subtree, or right after the node), one on the other side before it. It lands in the gap of the order
-- where it belongs: the odd place after a node, or the bottom line frame before every node.
function Room.Line(x1, y1, z1, x2, y2, z2, r, g, b, a, thick)
    if not (meshOk and haveBasis and orderValid and lineFrame) then return end
    thick = thick or 1
    local s = nSeg + 1
    nSeg = s
    local o = s * 11 - 11
    if reuse then
        if s <= nSegLast and SI[o + 1] == x1 and SI[o + 2] == y1 and SI[o + 3] == z1 and SI[o + 4] == x2
            and SI[o + 5] == y2 and SI[o + 6] == z2 and SI[o + 7] == r and SI[o + 8] == g and SI[o + 9] == b
            and SI[o + 10] == a and SI[o + 11] == thick then
            local first = SPS[s]
            local last = first + SPN[s] - 1
            for j = first, last do
                local fr = PF[j]
                fr.lineUsed = fr.lineUsed + 1
            end
            nPl = last
            nMarks = nMarks + SMK[s]
            return
        end
        reuse = false
    end
    SI[o + 1], SI[o + 2], SI[o + 3], SI[o + 4], SI[o + 5], SI[o + 6] = x1, y1, z1, x2, y2, z2
    SI[o + 7], SI[o + 8], SI[o + 9], SI[o + 10], SI[o + 11] = r, g, b, a, thick
    SPS[s], SPN[s], SMK[s] = nPl + 1, 0, 0
    local d1 = (x1 - ex) * Fx + (y1 - ey) * Fy + (z1 - ez) * Fz
    local d2 = (x2 - ex) * Fx + (y2 - ey) * Fy + (z2 - ez) * Fz
    if d1 < NEAR and d2 < NEAR then return end
    if d1 < NEAR then
        local t = (NEAR - d1) / (d2 - d1)
        x1, y1, z1 = x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, z1 + (z2 - z1) * t
    elseif d2 < NEAR then
        local t = (NEAR - d2) / (d1 - d2)
        x2, y2, z2 = x2 + (x1 - x2) * t, y2 + (y1 - y2) * t, z2 + (z1 - z2) * t
    end
    o = nMarks * 7
    nMarks = nMarks + 1
    SMK[s] = 1
    MKS[o + 1], MKS[o + 2], MKS[o + 3], MKS[o + 4], MKS[o + 5], MKS[o + 6], MKS[o + 7] = x1, y1, z1, x2, y2, z2, thick
    local S = LS
    local sp = 1
    S[1], S[2], S[3], S[4], S[5], S[6], S[7] = 1, x1, y1, z1, x2, y2, z2
    while sp > 0 do
        local q = sp * 7 - 7
        local k, ax, ay, az, bx, by, bz = S[q + 1], S[q + 2], S[q + 3], S[q + 4], S[q + 5], S[q + 6], S[q + 7]
        sp = sp - 1
        local na, nb, nc, nd = NA[k], NB[k], NC[k], ND[k]
        local s1, s2 = na * ax + nb * ay + nc * az + nd, na * bx + nb * by + nc * bz + nd
        local c1 = (s1 > LINE_EPS) and 1 or ((s1 < -LINE_EPS) and -1 or 0)
        local c2 = (s2 > LINE_EPS) and 1 or ((s2 < -LINE_EPS) and -1 or 0)
        if c1 * c2 < 0 then                                       -- straddles: both halves go on at this node
            local t = s1 / (s1 - s2)
            local mx, my, mz = ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t
            q = sp * 7
            S[q + 1], S[q + 2], S[q + 3], S[q + 4], S[q + 5], S[q + 6], S[q + 7] = k, ax, ay, az, mx, my, mz
            S[q + 8], S[q + 9], S[q + 10], S[q + 11], S[q + 12], S[q + 13], S[q + 14] = k, mx, my, mz, bx, by, bz
            sp = sp + 2
        else
            local c = (c1 ~= 0) and c1 or c2                      -- lying in the plane: the camera's side
            local camSide = sideSign[k] and 1 or -1
            local ch, fr, p
            if c == 0 or c == camSide then                        -- after node k
                ch = sideSign[k] and NFR[k] or NBK[k]
                if ch == 0 then fr, p = roomFrames[frameOf[k]], pos[k] + 1 end
            else                                                  -- before node k
                ch = sideSign[k] and NBK[k] or NFR[k]
                if ch == 0 then
                    local rk = rankOf[k] - 1
                    if rk < 0 then
                        fr, p = lineFrame, 0
                    else
                        local j = orderNode[rk]
                        fr, p = roomFrames[frameOf[j]], pos[j] + 1
                    end
                end
            end
            if ch ~= 0 then
                q = sp * 7
                S[q + 1], S[q + 2], S[q + 3], S[q + 4], S[q + 5], S[q + 6], S[q + 7] = ch, ax, ay, az, bx, by, bz
                sp = sp + 1
            else
                PlaceSeg(fr, p, ax, ay, az, bx, by, bz, r, g, b, a, thick)
            end
        end
    end
    SPN[s] = nPl - SPS[s] + 1
end
end

-- The height of the room's floor at (x, y): the floor triangle there whose height is nearest to hint (within
-- 1.5 yd), else hint.
function Room.FloorZ(x, y, hint)
    local cell = floorCells and meshOk and floorCells[floor(x / 8) * 1000 + floor(y / 8)]
    if not cell then return hint end
    local best, bestGap
    for n = 1, #cell do
        local i = cell[n]
        local a, b, c = TRI[i * 4 - 3], TRI[i * 4 - 2], TRI[i * 4 - 1]
        local ax, ay, bx, by, qx, qy = WX[a], WY[a], WX[b], WY[b], WX[c], WY[c]
        local det = (by - qy) * (ax - qx) + (qx - bx) * (ay - qy)
        if det ~= 0 then
            local w1 = ((by - qy) * (x - qx) + (qx - bx) * (y - qy)) / det
            local w2 = ((qy - ay) * (x - qx) + (ax - qx) * (y - qy)) / det
            local w3 = 1 - w1 - w2
            if w1 >= -0.01 and w2 >= -0.01 and w3 >= -0.01 then
                local z = w1 * WZ[a] + w2 * WZ[b] + w3 * WZ[c]
                local gap = abs(z - hint)
                if gap < 1.5 and (not bestGap or gap < bestGap) then best, bestGap = z, gap end
            end
        end
    end
    return best or hint
end

---------------------------------------------------------------------------
-- Setup and control
---------------------------------------------------------------------------

-- view: the clipping frame everything hangs in; sc: its ModelScene; lv: frame levels above the view's own
-- (lines, room0, scene, ...); near: the scene's near clip.
function Room.Attach(v, sc, lv, near)
    view, scene, LVt = v, sc, lv
    if type(near) == "number" and near > 0 then NEAR = near end
    if not lineFrame then
        lineFrame = CreateFrame("Frame", nil, view)
        lineFrame:SetAllPoints(view)
        lineFrame.free, lineFrame.lines, lineFrame.lineUsed, lineFrame.idx = {}, {}, 0, 0
    end
    V = view:GetFrameLevel()
    lineFrame:SetFrameLevel(V + LVt.lines)
    scene:SetFrameLevel(V + LVt.scene)
end

-- Hide everything and forget the camera (a new try, another encounter): nothing is drawn, and no mark is put into
-- the order, until the camera has been measured again.
function Room.Clear()
    for j = 1, nLive do
        local tx = liveList[j]
        if tx.shown then
            tx:Hide()
            tx.shown = false
        end
        live[tx.key] = nil
        Free(tx)
        liveList[j] = nil
    end
    nLive = 0
    CTL.epoch = CTL.epoch + 1
    haveBasis = false
    for f = 1, #roomFrames do
        roomFrames[f].lineUsed = 0
        HideLines(roomFrames[f], 1)
    end
    if lineFrame then
        lineFrame.lineUsed = 0
        HideLines(lineFrame, 1)
    end
    nMarks, nLeaves, nClipped, nCapped = 0, 0, 0, 0
    wipe(splitPrev)
    wipe(splitCur)
    dirty, forceOrder = true, true
    camKey[1] = nil
end

-- The room to draw (an encounter's arena.mesh): prepared once, nothing when it is the one already drawn.
-- -> false when it cannot be drawn in 3D (the flat floor map is used then).
local warned = false
function Room.SetMesh(mesh)
    if mesh == curMesh then return meshOk end
    Room.Clear()
    curMesh = mesh
    meshOk = (view ~= nil and type(mesh) == "table") and Prepare(mesh) or false
    if not meshOk and mesh and not warned then
        warned = true
        if ns.Print then ns:Print("Raid Trainer: this room has too many parts for the 3D renderer") end
    end
    return meshOk
end

-- Merge render options (Room.opts) and draw again.
function Room.SetOpts(t)
    if type(t) ~= "table" then return end
    local opts = Room.opts
    local was = opts.opaque ~= false
    for k, v in pairs(t) do opts[k] = v end
    if (opts.opaque ~= false) ~= was and meshOk then
        Room.Clear()                                     -- the pools change: every piece comes back from its new one
        ComputePools()
    end
    dirty = true
end

---------------------------------------------------------------------------
-- Reports (the test hooks in UI.lua, spec section 8)
---------------------------------------------------------------------------

-- tau: the bound the picture on screen was drawn with; tauNext: what the next redraw uses; capped: pieces drawn
-- whole past the hard cap although over the bound; redone: how often the last redraw was collected again coarser;
-- textures: room textures made so far (all frames, all rooms); lent: textures that moved to another frame.
function Room.Stats()
    return { tau = CTL.used, tauNext = CTL.tau, target = tonumber(Room.opts.target) or CTL.target, hardCap = hardCap,
             leaves = nLeaves, clipped = nClipped, capped = nCapped, redone = stats.redone, copies = 0, copyActors = 0,
             lines = Room.ShownLines(), frames = nFrames, nodes = nNodes, prims = nPrims, redraw = stats.redraw,
             redraws = stats.redraws, pass1b = stats.pass1b, ms = 0, selfCheckPx = stats.selfCheckPx,
             midpoints = nPts - nV, collided = false, dilate = 0, textures = stats.textures, lent = stats.lent }
end

function Room.ShownTextures() return nLive end

function Room.ShownLines()
    local n = 0
    for f = 1, nFrames do
        local ls = roomFrames[f].lines
        for i = 1, #ls do if ls[i].shown then n = n + 1 end end
    end
    if lineFrame then
        for _, l in pairs(lineFrame.lines) do if l.shown then n = n + 1 end end
    end
    return n
end

function Room.Frames()
    local t = {}
    for f = 1, nFrames do t[f] = roomFrames[f] end
    return t
end

function Room.CopyFrames() return {} end

-- The order invariants: nodes, frames, distinct (frame, place) pairs over the nodes, wrong = live pieces not on
-- their node's (frame, place), the shown mark lines as { frame, pos } (frame 0: the bottom line frame), pieces
-- drawn, and every frame's level.
function Room.Order()
    if not (meshOk and orderValid) then return nil end
    local seen, distinct = {}, 0
    for k = 1, nNodes do
        local q = frameOf[k] * 64 + pos[k]
        if not seen[q] then
            seen[q] = true
            distinct = distinct + 1
        end
    end
    local wrong = 0
    for j = 1, nLive do
        local tx = liveList[j]
        local k = QN[floor(tx.key / KP)]
        if not k or tx.frame ~= frameOf[k] or tx.pos ~= pos[k] then wrong = wrong + 1 end
    end
    local lines = {}
    for f = 1, nFrames do
        local ls = roomFrames[f].lines
        for i = 1, #ls do
            if ls[i].shown then lines[#lines + 1] = { frame = f, pos = ls[i].pos } end
        end
    end
    if lineFrame then
        for _, l in pairs(lineFrame.lines) do
            if l.shown then lines[#lines + 1] = { frame = 0, pos = l.pos } end
        end
    end
    local levels = {}
    for f = 1, nFrames do levels[f] = roomFrames[f].lvl end
    return { nodes = nNodes, frames = nFrames, distinct = distinct, wrong = wrong, lines = lines, pieces = nLeaves,
             levels = levels }
end

-- The mark segments drawn this frame: { x1, y1, z1, x2, y2, z2, thickness } in arena coordinates, after the
-- near-plane cut and before the tree cut them up.
function Room.Marks()
    local out = {}
    for i = 1, nMarks do
        local o = i * 7 - 7
        out[i] = { MKS[o + 1], MKS[o + 2], MKS[o + 3], MKS[o + 4], MKS[o + 5], MKS[o + 6], MKS[o + 7] }
    end
    return out
end
