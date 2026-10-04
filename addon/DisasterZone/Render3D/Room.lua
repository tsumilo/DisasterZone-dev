if DisasterZoneBoot and DisasterZoneBoot.Run("Render3D/Room.lua", ...) then return end -- DisasterZone Render3D/Room.lua
-- ns.Render3D.NewRoom(): a room renderer (v2, dev/docs/trainer_renderer_v2/spec.md), shared by the Raid Trainer and
-- the strategy board's 3D view. Every call makes an independent renderer (its own frames, textures and camera), so
-- each view draws its own room; Render3D/View.lua sets one up with its ModelScene.
--
-- The room is Blizzard's own mesh (ns.RoomFloors.<key>.mesh). Every piece of it is a 1 x 1 Texture whose four
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
--  * The models stand in one ModelScene over all of the room; the room pieces (and mark lines) in front of each model
--    are drawn once more above the scene, clipped in Lua to that model (the copies, spec 5.13). Under a still camera
--    only the models whose copies can change are copied again (one that moved, and those its region covers).
--  * Room.CameraDistance keeps UI.lua's camera out of the walls (spec 5.2) and inside the room's footprint (through a
--    doorway the rays find nothing, and beyond it the room has nothing); a time controller moves the leaf target
--    to keep a moving frame near 4 ms in game (spec 5.11). The texture morph (spec 5.6) is there but ships off.
--  * Room.Project / Room.ScreenRay turn room points into screen points and back with the camera BeginFrame measured
--    (the strategy board picks the floor under the mouse with them).
local _, ns = ...

ns.Render3D = ns.Render3D or {}

-- (The whole renderer is the body of NewRoom, written at the file's own indent: its locals are a function's locals,
-- with the same limits a main chunk has - 200 locals, 60 upvalues per function.)
function ns.Render3D.NewRoom(label)

local Room = { opts = {}, label = label or "3D view" }

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
-- texBudget: room textures made before a frame with none free borrows a hidden one from another frame (SetParent).
-- Textures never leave their frame otherwise, so a session makes the sum of what every frame ever needed at once: in
-- 12000 frames of walking about with any pitch and zoom 13k in Teron and 19k in Vashj, still slowly growing; one
-- frame alone (a floor right under a low camera) can hold 2000. The budget is set past what normal play makes;
-- borrowing is the last resort after it (each texture keeps 8 numbers, about 0.7 KB with its widget table).
-- epoch: counts the changes of camera, order and room that move mark lines (Room.Line reuses a still frame's).
-- target / targetMin / targetMax / targetMs, over, under, t0: the time controller (spec 5.11, StopClock) moves the
-- leaf target between 900 and 2800 to keep a camera-driven redraw near 6 ms (Room.opts.target, when set, wins).
-- Tuned towards sharp, steady textures (the user's priority; the spec had 1600 / 2200 / 4 ms): a client with time
-- to spare reaches tau 2, a slow one falls back to coarser pieces (up to tau 5) instead of losing frames.
local CTL = { start = 2.0, min = 1.5, max = 5.0, merge = 0.75, target = 2000, cap = 3200, tau = 2.0, used = 2.0,
              limit = 10.0, midCap = 16384, texBudget = 20000, epoch = 0,
              targetMin = 900, targetMax = 2800, targetMs = 6.0, over = 0, under = 0,
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
-- Texture files drawn tinted (r, g, b, alpha): the rooms' water is the game's grey river ripples (fast_a.1.blp,
-- 219885) in blue, opaque (dev/generators/gen_rooms.py WATER_TEX: a see-through piece redrawn over a model would
-- show twice).
local TINT = { [219885] = { 0.5, 0.78, 1, 1 } }
local function Paint(tx, L)
    local t = TINT[floor(tx.pool / 4)]
    if t then
        tx:SetVertexColor(L * t[1], L * t[2], L * t[3], t[4])
    else
        tx:SetVertexColor(L, L, L, 1)
    end
    tx.light = L
end
local VUL, VLL = UPPER_LEFT_VERTEX or 1, LOWER_LEFT_VERTEX or 2
local VUR, VLR = UPPER_RIGHT_VERTEX or 3, LOWER_RIGHT_VERTEX or 4

-- Room.opts (spec section 8, UI._RenderOpts; in game also /dz trainer render): tau (a number fixes the bound and
-- turns the controllers off), adaptive (the count controller), adaptiveTime (the time controller), target (fixes the
-- leaf target; unset: the time controller's), hardCap, morph, copies, collision (read by UI.lua's camera), opaque,
-- quads (the generator's quad pairs; off: every triangle a texture of its own), camDt (UI.lua). Not used:
-- siblingQuads, dilate (spec 12.10: no pose needs it). Not in the spec (tests and tuning; unset = CTL's): texBudget,
-- midCap.
-- The morph ships off (spec step 8: kept only when it makes the walk's largest pop 30% smaller; measured, it made it
-- larger - 3.4 / 2.6 px against 2.2 / 2.4 - and doubled the texels' misplacement: a piece is halved across its
-- longest edge in the room when any edge is over tau, but its midpoint slides by that edge's own offset, often far
-- under tau, so the halves keep showing the parent's picture for levels).
do
    local DEFAULTS = { adaptive = true, adaptiveTime = true, hardCap = CTL.cap, morph = false, quads = true,
                       copies = true, collision = true, siblingQuads = false, opaque = true, dilate = 0, camDt = false }
    Room.Defaults = {}
    for k, v in pairs(DEFAULTS) do Room.opts[k], Room.Defaults[k] = v, v end
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
local CAMT = {}                                                    -- the same camera for the copies (spec 5.13)

-- mark lines
local MKS, nMarks = {}, 0                                          -- segments drawn this frame (UI._Marks)
local linesChanged = false
-- the placed pieces of this frame's mark segments, for the copies: per placement 6 arena coordinates (A), 4 screen
-- coordinates (S), its key in the order (K: 2 rank + 1 of the node it follows, -1 before every node) and colour and
-- thickness (C, 5); n placements
local MKR = { A = {}, S = {}, K = {}, C = {}, n = 0 }

local floorCells, TRI                                              -- floor triangles by 4 yd square (FloorZ)

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
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge     -- (the room's footprint: CameraDistance)
    for i = 1, nV do
        local o = i * 6 - 6
        local x, y = v[o + 1], v[o + 2]
        WX[i], WY[i], WZ[i] = x, y, v[o + 3]
        TU[i], TV[i], DU[i], DV[i] = v[o + 4], v[o + 5], v[o + 4], v[o + 5]
        PS[i], MA[i], MB[i] = 0, nil, nil
        if x < x0 then x0 = x end
        if x > x1 then x1 = x end
        if y < y0 then y0 = y end
        if y > y1 then y1 = y end
    end
    CTL.fx0, CTL.fy0, CTL.fx1, CTL.fy1 = x0, y0, x1, y1
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
    local pair = (mesh.version == 2 and Room.opts.quads ~= false) and mesh.pair or nil
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
-- than fit under the scene: the view's levels room0 .. scene - 1 (Room.Attach; ROOM_FRAMES_MAX before it).
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
    local most = (LVt and LVt.scene and LVt.room0) and (LVt.scene - LVt.room0) or ROOM_FRAMES_MAX
    return nf <= most
end

-- The floors (normal at most ~45 degrees from up) by 4 yd squares, for FloorZ (a moving ring asks 21 times a frame).
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
            for gx = floor(x0 / 4), floor(x1 / 4) do
                for gy = floor(y0 / 4), floor(y1 / 4) do
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

-- An axis-aligned box (6 numbers from B[o + 1]) against the frustum planes still in mask (bit 1, 2, 4, 8 = left,
-- right, bottom, top; 16 = near): -> -1 when it lies entirely outside one of them, else the planes it is not
-- entirely inside (a box inside a plane has all its children inside it too, so a subtree tests fewer and fewer
-- planes on the way down, and a node entirely in view tests none, nor do its pieces).
local BoxTest
do
local PLIST, PBIT = {}, {}                       -- mask -> plane offsets in FR; plane offset -> its bit
for i = 0, 4 do PBIT[i * 4 + 1] = 2 ^ i end
for m = 0, 31 do
    local list, r = {}, m
    for i = 0, 4 do
        if r % 2 == 1 then list[#list + 1] = i * 4 + 1 end
        r = floor(r / 2)
    end
    PLIST[m] = list
end
function BoxTest(B, o, mask)
    local x0, y0, z0, x1, y1, z1 = B[o + 1], B[o + 2], B[o + 3], B[o + 4], B[o + 5], B[o + 6]
    local list = PLIST[mask]
    for j = 1, #list do
        local i = list[j]
        local nx, ny, nz, nd = FR[i], FR[i + 1], FR[i + 2], FR[i + 3]
        local ax, bx, ay, by, az, bz = x1, x0, y1, y0, z1, z0       -- the corner furthest along n, and nearest
        if nx < 0 then ax, bx = x0, x1 end
        if ny < 0 then ay, by = y0, y1 end
        if nz < 0 then az, bz = z0, z1 end
        if nx * ax + ny * ay + nz * az + nd < 0 then return -1 end
        if nx * bx + ny * by + nz * bz + nd >= 0 then mask = mask - PBIT[i] end
    end
    return mask
end
end
local stM = {}                                   -- Collect's stack: the planes each subtree still has to test
local inView, inNear = false, false              -- the node being collected lies entirely in view / before NEAR

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
            ns:Print(("%s: the room may not line up with the characters (projection check off by %d px). "
                .. "Please report this."):format(Room.label, floor(e + 0.5)))
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
    local C = CAMT
    C.ex, C.ey, C.ez, C.Fx, C.Fy, C.Fz, C.Rx, C.Ry, C.Ux, C.Uy, C.Uz = ex, ey, ez, Fx, Fy, Fz, Rx, Ry, Ux, Uy, Uz
    C.cx, C.cy, C.exx, C.exy, C.eyx, C.eyy, C.W, C.H = cx, cy, exx, exy, eyx, eyy, w, h
    C.stamp = (C.stamp or 0) + 1
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
-- are looked at (spec 5.6). With the morph on, a midpoint's texture coordinate (DU, DV) follows its edge's error: the
-- true midpoint of the edge lands e = L |d1 - d2| / (2 (d1 + d2)) px from where the unhalved parent showed it. Up to
-- e = tau (where a piece is halved, and below 0.75 tau, where it is joined again) the midpoint shows what the parent
-- showed there - (d1 uv1 + d2 uv2) / (d1 + d2), spec A.2 - so neither halving nor joining can be seen; from tau to
-- 2 tau it slides to the true texel. A pure function of the edge: both pieces sharing it show the same.
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
    if morphOn then
        local a = MA[id]
        if a then                                   -- (its edge's ends are the corners of the piece just halved)
            local b = MB[id]
            local mu, mv = (DU[a] + DU[b]) * 0.5, (DV[a] + DV[b]) * 0.5
            local da, db = PD[a], PD[b]
            if da > NEAR and db > NEAR then
                local lx, ly = PX[a] - PX[b], PY[a] - PY[b]
                local t = (sqrt(lx * lx + ly * ly) * abs(da - db) / (2 * (da + db)) - CTL.used) / CTL.used
                if t < 1 then
                    if t < 0 then t = 0 end
                    local s = da + db
                    local au, av = (da * DU[a] + db * DU[b]) / s, (da * DV[a] + db * DV[b]) / s
                    mu, mv = au + (mu - au) * t, av + (mv - av) * t
                end
            end
            DU[id], DV[id] = mu, mv
        end
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
            tx.pool, tx.light = pool, nil                -- (the colour goes with the file: Paint again)
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

-- One piece on screen (spec 5.9.1): n = 3 (c1, c2, c3; c4 == c3) or 4 (cyclic c1..c4). UL = c1, LL = c2,
-- UR = c4, LR = c3: a triangle's UR and LR are the same corner, a quad's diagonal LL - UR is c2 - c4.
-- tx: the piece's texture from the last redraw (false: it gets one).
-- A texture shows its corners' DU, DV as they are this redraw (what the copies read): a key's corners are always the
-- same points, so without the morph they never change; a cut piece and, with the morph, a piece with a midpoint
-- corner send theirs every time (the texture keeps no copy of them: spec 5.9.2's UVMoved would need 8 numbers on
-- every one of the 10-20 thousand textures a long session makes).
local function Emit(q, tx)
    local p, key, n, c1, c2, c3, c4, clipped = LR[q + 1], LR[q + 2], LR[q + 3], LR[q + 4], LR[q + 5], LR[q + 6],
        LR[q + 7], LR[q + 8]
    local k = QN[p]
    if not tx then
        tx = Acquire(frameOf[k], QPOOL[p])
        live[key] = tx
        nLive = nLive + 1
        liveList[nLive] = tx
        tx.key, tx.uvOk = key, false
        local L = QL[p]
        if tx.light ~= L then Paint(tx, L) end
    end
    tx.gen = gen
    -- (a key always has the same corners, so without the morph their texture coordinates never change; a piece cut
    -- at the near plane has cut corners, and its key shows the whole piece again once it is clear of the plane: so a
    -- cut send never counts as the whole piece's)
    if clipped or not tx.uvOk or (morphOn and (c1 > nV or c2 > nV or c3 > nV or c4 > nV)) then
        tx:SetTexCoord(DU[c1], DV[c1], DU[c2], DV[c2], DU[c4], DV[c4], DU[c3], DV[c3])
        tx.uvOk = not clipped
    end
    local pp = pos[k]
    if tx.pos ~= pp then
        tx:SetDrawLayer(LAYERS[floor(pp / 16) + 1], pp % 16 - 8)
        tx.pos = pp
    end
    local x1, y1, x2, y2, x3, y3, x4, y4 = PX[c1], PY[c1], PX[c2], PY[c2], PX[c3], PY[c3], PX[c4], PY[c4]
    tx:SetVertexOffset(VUL, x1 - ox + 0.5, y1 - oy - 0.5)
    tx:SetVertexOffset(VLL, x2 - ox + 0.5, y2 - oy + 0.5)
    tx:SetVertexOffset(VUR, x4 - ox - 0.5, y4 - oy - 0.5)
    tx:SetVertexOffset(VLR, x3 - ox - 0.5, y3 - oy + 0.5)
    if not tx.shown then
        tx:Show()
        tx.shown = true
    end
    -- its screen box, for the copies' bins (spec 5.13.4)
    if x2 < x1 then x1, x2 = x2, x1 end
    if x4 < x3 then x3, x4 = x4, x3 end
    if y2 < y1 then y1, y2 = y2, y1 end
    if y4 < y3 then y3, y4 = y4, y3 end
    LR[q + 9], LR[q + 10] = (x1 < x3) and x1 or x3, (y1 < y3) and y1 or y3
    LR[q + 11], LR[q + 12] = (x2 > x4) and x2 or x4, (y2 > y4) and y2 or y4
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
    local o = i * 12 - 12
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
    local da, db, dc = PD[a], PD[b], PD[c]
    if not inView then
        -- out of view (Out3, written out): every corner behind the near plane or outside one side of the view (a
        -- node whose box lies entirely in view skips this: none of its pieces can be out)
        if da < NEAR and db < NEAR and dc < NEAR then return end
        local ra, ua, rb, ub, rc, uc = PR[a], PU[a], PR[b], PU[b], PR[c], PU[c]
        local la, lb, lc = ra * exx + ua * eyx, rb * exx + ub * eyx, rc * exx + uc * eyx
        if (la + cl * da < 0 and lb + cl * db < 0 and lc + cl * dc < 0) or (cr * da < la and cr * db < lb and cr * dc < lc)
        then return end
        la, lb, lc = ra * exy + ua * eyy, rb * exy + ub * eyy, rc * exy + uc * eyy
        if (la + cb * da < 0 and lb + cb * db < 0 and lc + cb * dc < 0) or (ct * da < la and ct * db < lb and ct * dc < lc)
        then return end
    end
    local key = p * KP + path * 4
    local crossing = not inNear and (da < NEAR or db < NEAR or dc < NEAR)
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
    local da, db, dc, dd = PD[a], PD[b], PD[c], PD[d]
    if not inView then
        -- out of view (Out4, written out)
        if da < NEAR and db < NEAR and dc < NEAR and dd < NEAR then return end
        local ra, ua, rb, ub, rc, uc, rd, ud = PR[a], PU[a], PR[b], PU[b], PR[c], PU[c], PR[d], PU[d]
        local la, lb, lc, ld = ra * exx + ua * eyx, rb * exx + ub * eyx, rc * exx + uc * eyx, rd * exx + ud * eyx
        if (la + cl * da < 0 and lb + cl * db < 0 and lc + cl * dc < 0 and ld + cl * dd < 0)
            or (cr * da < la and cr * db < lb and cr * dc < lc and cr * dd < ld) then return end
        la, lb, lc, ld = ra * exy + ua * eyy, rb * exy + ub * eyy, rc * exy + uc * eyy, rd * exy + ud * eyy
        if (la + cb * da < 0 and lb + cb * db < 0 and lc + cb * dc < 0 and ld + cb * dd < 0)
            or (ct * da < la and ct * db < lb and ct * dc < lc and ct * dd < ld) then return end
    end
    local key = p * KP + path * 4
    local crossing = not inNear and (da < NEAR or db < NEAR or dc < NEAR or dd < NEAR)
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
    stN[1], stP[1], stM[1] = 1, 0, 31
    while sp > 0 and not aborted do
        local k, ph = stN[sp], stP[sp]
        if ph == 0 then
            local m = stM[sp]
            if m > 0 then m = BoxTest(SB, k * 6 - 6, m) end
            if m < 0 then
                sp = sp - 1                                           -- the whole subtree is out of view
            else
                stP[sp], stM[sp] = 1, m
                local far = sideSign[k] and NBK[k] or NFR[k]
                if far ~= 0 then
                    sp = sp + 1
                    stN[sp], stP[sp], stM[sp] = far, 0, m
                end
            end
        elseif ph == 1 then
            stP[sp] = 2
            local s, m = side[k], stM[sp]
            if (s > EPS_SIDE or s < -EPS_SIDE) and FP[k] <= LP[k] then
                if m > 0 then m = BoxTest(OB, k * 6 - 6, m) end
                if m >= 0 then
                    inView, inNear = m == 0, m < 16
                    local want = (s > 0) and 1 or -1                  -- prims facing the camera
                    for p = FP[k], LP[k] do
                        if QO[p] == want then
                            local d = QD[p]
                            if d == 0 then RefineTri(p, 1, QA[p], QB[p], QC[p], 0)
                            else RefineQuad(p, 1, QA[p], QB[p], QC[p], d, 0) end
                        end
                    end
                end
            end
            local near = sideSign[k] and NFR[k] or NBK[k]
            if near ~= 0 then
                sp = sp + 1
                stN[sp], stP[sp], stM[sp] = near, 0, stM[sp - 1]
            end
        else
            sp = sp - 1
        end
    end
    inView, inNear = false, false
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
    local morph = o.morph ~= false
    if morph ~= morphOn then                                           -- (midpoints kept with the other kind of uv,
        morphOn, wipeMid = morph, true                                 -- and pieces showing it: send theirs again)
        for j = 1, nLive do liveList[j].uvOk = false end
    end
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
        gen = gen + 1                                                  -- (the morph depends on tau: prepare again)
    end
    redoOK = false
    local g = gen
    for i = 1, nLeaves do                                              -- pieces drawn again keep their texture
        local tx = live[LR[i * 12 - 10]]
        LT[i] = tx or false
        if tx then tx.gen = g end
    end
    Release()
    for i = 1, nLeaves do Emit(i * 12 - 12, LT[i]) end
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
    local o, C = Room.opts, CTL
    C.t0 = nil
    if camDriven and o.adaptiveTime ~= false and type(o.tau) ~= "number" and o.adaptive ~= false
        and debugprofilestop then
        C.t0 = debugprofilestop()                                     -- (StopClock, at the end of DrawCopies)
    end
    C.epoch = C.epoch + 1
    Pass1()
    Pass2()
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

-- The time controller (spec 5.11; in game only: opts.adaptiveTime and debugprofilestop): a camera-driven redraw
-- starts the clock in DrawRoom, DrawCopies stops it (the room, its mark lines and the copies). Three such redraws in
-- a row over 6 ms lower the leaf target by 10% (not under 900); sixty in a row under 3.6 ms raise it by 5% (not
-- over 2800). The count controller then moves tau towards the target.
local function StopClock()
    local C = CTL
    local t0 = C.t0
    if not t0 then return end
    C.t0 = nil
    local ms = debugprofilestop() - t0
    stats.ms = ms
    if ms > C.targetMs then
        C.over, C.under = C.over + 1, 0
        if C.over >= 3 then C.over, C.target = 0, max(C.targetMin, C.target * 0.9) end
    elseif ms < 0.6 * C.targetMs then
        C.under, C.over = C.under + 1, 0
        if C.under >= 60 then C.under, C.target = 0, math.min(C.targetMax, C.target * 1.05) end
    else
        C.over, C.under = 0, 0
    end
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
-- The walk down the tree does not depend on the camera: at a node a piece always goes on into the child on its own
-- side (the camera only decides, at the node where it lands, whether it goes after or before it - and which child a
-- piece lying in a plane takes). So each segment's pieces (6 coordinates, the node it lands at and its side there)
-- are kept while its ends and the room stay the same (DCI: 6 coordinates and the mesh; DCP: { n, ... } or false
-- when a piece lay in a plane with a child to choose).
local DCI, DCP = {}, {}

local function NewLine(fr, i)
    local l = fr:CreateLine(nil, "BACKGROUND")
    if l.SetSnapToPixelGrid then l:SetSnapToPixelGrid(false) end
    if l.SetTexelSnappingBias then l:SetTexelSnappingBias(0) end
    l.shown = true
    fr.lines[i] = l
    return l
end

-- One placed segment: the next line of frame fr's pool at place p, from a to b (arena, in front of the camera);
-- key: its place in the order (2 rank + 1 of the node it follows, -1 before every node), recorded for the copies.
local function PlaceSeg(fr, p, key, ax, ay, az, bx, by, bz, r, g, b, a, thick)
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
    local R, q = MKR, nPl * 6 - 6
    local RA, RS, RC = R.A, R.S, R.C
    RA[q + 1], RA[q + 2], RA[q + 3], RA[q + 4], RA[q + 5], RA[q + 6] = ax, ay, az, bx, by, bz
    q = nPl * 4 - 4
    RS[q + 1], RS[q + 2], RS[q + 3], RS[q + 4] = x1, y1, x2, y2
    q = nPl * 5 - 5
    RC[q + 1], RC[q + 2], RC[q + 3], RC[q + 4], RC[q + 5] = r, g, b, a, thick
    R.K[nPl] = key
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
    MKR.n = nPl
end

-- A segment's pieces into P (see DCI / DCP): -> false when one lay in a plane with a child to choose.
local function Descend(P, x1, y1, z1, x2, y2, z2)
    local S, sp, n = LS, 1, 0
    S[1], S[2], S[3], S[4], S[5], S[6], S[7] = 1, x1, y1, z1, x2, y2, z2
    while sp > 0 do
        local q = sp * 7 - 7
        local k, ax, ay, az, bx, by, bz = S[q + 1], S[q + 2], S[q + 3], S[q + 4], S[q + 5], S[q + 6], S[q + 7]
        sp = sp - 1
        local na, nb, nc, nd = NA[k], NB[k], NC[k], ND[k]
        local s1, s2 = na * ax + nb * ay + nc * az + nd, na * bx + nb * by + nc * bz + nd
        local c1 = (s1 > LINE_EPS) and 1 or ((s1 < -LINE_EPS) and -1 or 0)
        local c2 = (s2 > LINE_EPS) and 1 or ((s2 < -LINE_EPS) and -1 or 0)
        if c1 * c2 < 0 then
            local t = s1 / (s1 - s2)
            local mx, my, mz = ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t
            q = sp * 7
            S[q + 1], S[q + 2], S[q + 3], S[q + 4], S[q + 5], S[q + 6], S[q + 7] = k, ax, ay, az, mx, my, mz
            S[q + 8], S[q + 9], S[q + 10], S[q + 11], S[q + 12], S[q + 13], S[q + 14] = k, mx, my, mz, bx, by, bz
            sp = sp + 2
        else
            local c = (c1 ~= 0) and c1 or c2
            local ch = 0
            if c > 0 then ch = NFR[k] elseif c < 0 then ch = NBK[k]
            elseif NFR[k] ~= 0 or NBK[k] ~= 0 then return false end
            if ch ~= 0 then
                q = sp * 7
                S[q + 1], S[q + 2], S[q + 3], S[q + 4], S[q + 5], S[q + 6], S[q + 7] = ch, ax, ay, az, bx, by, bz
                sp = sp + 1
            else
                q = n * 8
                P[q + 1], P[q + 2], P[q + 3], P[q + 4], P[q + 5], P[q + 6], P[q + 7], P[q + 8] = ax, ay, az, bx, by, bz,
                    k, c
                n = n + 1
            end
        end
    end
    P.n = n
    return true
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
    if d1 >= NEAR and d2 >= NEAR then                         -- (all in front: the kept pieces, placed for this camera)
        o = s * 7 - 7
        local P = DCP[s]
        if not (DCI[o + 1] == x1 and DCI[o + 2] == y1 and DCI[o + 3] == z1 and DCI[o + 4] == x2 and DCI[o + 5] == y2
            and DCI[o + 6] == z2 and DCI[o + 7] == curMesh) then
            P = P or {}
            if not Descend(P, x1, y1, z1, x2, y2, z2) then P.n = false end
            DCP[s] = P
            DCI[o + 1], DCI[o + 2], DCI[o + 3], DCI[o + 4], DCI[o + 5], DCI[o + 6], DCI[o + 7] = x1, y1, z1, x2, y2, z2,
                curMesh
        end
        if P.n then
            for q = 0, P.n * 8 - 8, 8 do
                local k, c = P[q + 7], P[q + 8]
                local fr, p, key
                if c == 0 or (c > 0) == (sideSign[k] == true) then          -- after node k
                    fr, p, key = roomFrames[frameOf[k]], pos[k] + 1, 2 * rankOf[k] + 1
                else                                                         -- before node k
                    local rk = rankOf[k] - 1
                    if rk < 0 then
                        fr, p, key = lineFrame, 0, -1
                    else
                        local j = orderNode[rk]
                        fr, p, key = roomFrames[frameOf[j]], pos[j] + 1, 2 * rk + 1
                    end
                end
                PlaceSeg(fr, p, key, P[q + 1], P[q + 2], P[q + 3], P[q + 4], P[q + 5], P[q + 6], r, g, b, a, thick)
            end
            SPN[s] = nPl - SPS[s] + 1
            return
        end
    end
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
            local ch, fr, p, key
            if c == 0 or c == camSide then                        -- after node k
                ch = sideSign[k] and NFR[k] or NBK[k]
                if ch == 0 then fr, p, key = roomFrames[frameOf[k]], pos[k] + 1, 2 * rankOf[k] + 1 end
            else                                                  -- before node k
                ch = sideSign[k] and NBK[k] or NFR[k]
                if ch == 0 then
                    local rk = rankOf[k] - 1
                    if rk < 0 then
                        fr, p, key = lineFrame, 0, -1
                    else
                        local j = orderNode[rk]
                        fr, p, key = roomFrames[frameOf[j]], pos[j] + 1, 2 * rk + 1
                    end
                end
            end
            if ch ~= 0 then
                q = sp * 7
                S[q + 1], S[q + 2], S[q + 3], S[q + 4], S[q + 5], S[q + 6], S[q + 7] = ch, ax, ay, az, bx, by, bz
                sp = sp + 1
            else
                PlaceSeg(fr, p, key, ax, ay, az, bx, by, bz, r, g, b, a, thick)
            end
        end
    end
    SPN[s] = nPl - SPS[s] + 1
end
end

-- How far the camera may stand from the pivot (arena px, py, pz: the player's head) before something of the room is
-- in the way (spec 5.2). Five rays from the pivot to where the camera would be, the middle one and four through the
-- corners of the near plane's rectangle (0.35 yd right / left, 0.25 yd up / down), are run through the BSP tree front
-- to back; the first triangle any of them meets (either face) puts the camera 0.6 yd before it (not nearer the pivot
-- than 0.8 yd). Nor does the camera leave the room's footprint (the box of its points on the floor, 0.5 yd inside):
-- the room has nothing beyond it, so where all five rays find a way out (a doorway) the view would be the room from
-- outside, its one-sided walls from behind. c: the trainer's camera (fx, fy, fz in scene coordinates, mirror); want:
-- the distance wanted. The same pivot, direction and distance give the last answer without casting again.
-- -> distance, and whether something (a triangle or the footprint's edge) was in the way.
-- (In a function of its own: the main chunk's locals are kept for what runs every frame.)
Room.CameraDistance = (function()
    local X0, Y0, Z0, DX, DY, DZ = 0, 0, 0, 0, 0, 0
    local TOL2 = 0.05 * 0.05                     -- yd: a crossing this close outside a triangle still hits it
    local SIDE = 0.02                            -- yd: points this close to a plane lie in it
    local EDGE = 0.5                             -- yd: the camera stays this far inside the room's footprint
    local last = {}

    -- how far p may go along d (per unit of distance) and stay within lo .. hi
    local function ToEdge(p, d, lo, hi)
        if d > 1e-9 then return (hi - p) / d end
        if d < -1e-9 then return (lo - p) / d end
        return math.huge
    end

    -- Is the point (on node k's plane) inside one of k's triangles or quads, within 0.05 yd?
    local function Inside(k, x, y, z)
        local na, nb, nc = NA[k], NB[k], NC[k]
        for p = FP[k], LP[k] do
            local o = QO[p]
            if o ~= 0 then
                local n = (QD[p] == 0) and 3 or 4
                local inside = true
                for e = 1, n do
                    local i = (e == 1 and QA[p]) or (e == 2 and QB[p]) or (e == 3 and QC[p]) or QD[p]
                    local j = (e == n and QA[p]) or (e == 1 and QB[p]) or (e == 2 and QC[p]) or QD[p]
                    local ex_, ey_, ez_ = WX[j] - WX[i], WY[j] - WY[i], WZ[j] - WZ[i]
                    local qx, qy, qz = x - WX[i], y - WY[i], z - WZ[i]
                    -- (edge x to-point) . normal, signed by the prim's winding: >= 0 inside
                    local s = o * ((ey_ * qz - ez_ * qy) * na + (ez_ * qx - ex_ * qz) * nb + (ex_ * qy - ey_ * qx) * nc)
                    if s < 0 and s * s > TOL2 * (ex_ * ex_ + ey_ * ey_ + ez_ * ez_) then
                        inside = false
                        break
                    end
                end
                if inside then return true end
            end
        end
        return false
    end

    -- The first hit of the segment S(t) = P0 + t D, t0 <= t <= t1, in subtree k (front to back), or nil.
    local function Cast(k, t0, t1)
        if k == 0 then return nil end
        local na, nb, nc, nd = NA[k], NB[k], NC[k], ND[k]
        local s0 = na * (X0 + t0 * DX) + nb * (Y0 + t0 * DY) + nc * (Z0 + t0 * DZ) + nd
        local s1 = na * (X0 + t1 * DX) + nb * (Y0 + t1 * DY) + nc * (Z0 + t1 * DZ) + nd
        local c0 = (s0 > SIDE) and 1 or ((s0 < -SIDE) and -1 or 0)
        local c1 = (s1 > SIDE) and 1 or ((s1 < -SIDE) and -1 or 0)
        if c0 * c1 >= 0 then                                         -- no proper crossing
            if c0 + c1 > 0 then return Cast(NFR[k], t0, t1) end
            if c0 + c1 < 0 then return Cast(NBK[k], t0, t1) end
            return Cast(NFR[k], t0, t1) or Cast(NBK[k], t0, t1)      -- (lying in the plane)
        end
        local near, far = NBK[k], NFR[k]
        if c0 > 0 then near, far = far, near end
        local tm = t0 + (t1 - t0) * s0 / (s0 - s1)
        local h = Cast(near, t0, tm)
        if h then return h end
        if Inside(k, X0 + tm * DX, Y0 + tm * DY, Z0 + tm * DZ) then return tm end
        return Cast(far, tm, t1)
    end

    return function(px, py, pz, c, want)
        if not (meshOk and nNodes > 0) then return want, false end
        local fx, fy, fz, m = c.fx, c.fy, c.fz, c.mirror or 1
        if last[1] == px and last[2] == py and last[3] == pz and last[4] == fx and last[5] == fy and last[6] == fz
            and last[7] == want and last[8] == m and last[11] == curMesh then
            return last[9], last[10]
        end
        local flat = sqrt(fx * fx + fy * fy)
        local rx, ry = 0, 1
        if flat > 1e-6 then rx, ry = fy / flat, -fx / flat end
        local ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx
        fy, ry, uy = m * fy, m * ry, m * uy                          -- (arena coordinates)
        X0, Y0, Z0 = px, py, pz
        local tmin
        for i = 0, 4 do
            local a = (i == 0) and 0 or ((i <= 2) and 0.35 or -0.35)
            local b = (i == 0) and 0 or ((i % 2 == 1) and 0.25 or -0.25)
            DX, DY, DZ = -fx * want + a * rx + b * ux, -fy * want + a * ry + b * uy, -fz * want + b * uz
            local t = Cast(1, 0, 1)
            if t and t > 0 and (not tmin or t < tmin) then tmin = t end
        end
        local allowed = tmin and max(0.8, tmin * want - 0.6) or want
        if allowed > want then allowed = want end
        local hit = tmin ~= nil
        local C = CTL
        if C.fx0 then
            local edge = math.min(ToEdge(px, -fx, C.fx0 + EDGE, C.fx1 - EDGE),
                ToEdge(py, -fy, C.fy0 + EDGE, C.fy1 - EDGE))                       -- (fx, fy: per yard of distance)
            if edge < allowed then allowed, hit = max(0.8, edge), true end
        end
        last[1], last[2], last[3], last[4], last[5], last[6], last[7], last[8] = px, py, pz, c.fx, c.fy, c.fz, want, m
        last[9], last[10], last[11] = allowed, hit, curMesh
        return allowed, hit
    end
end)()

-- The height of the room's floor at (x, y): the floor triangle there whose height is nearest to hint (within
-- 1.5 yd), else hint.
function Room.FloorZ(x, y, hint)
    local cell = floorCells and meshOk and floorCells[floor(x / 4) * 1000 + floor(y / 4)]
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
-- Copies of the room over the models (spec 5.13)
---------------------------------------------------------------------------
-- The room is drawn under the single ModelScene, so every model is drawn over all of it. Where a model should be
-- hidden, the room pieces in front of it are drawn once more above the scene: for each model on screen (an
-- occluder) the pieces on the camera's side of a plane through it - family A: upright through its axis, facing the
-- camera; family B (the camera nearly over it): only what is nearer than all of it; skip (a corner behind the near
-- plane): nothing - clipped in Lua to its box on the screen. Along any ray from the eye such a set is a prefix (the
-- nearest surfaces first), so a copy never changes a room pixel: it shows the nearest surface there or nothing
-- (spec 5.13.6). Where boxes overlap, a copy also stays on the camera's side of every other occluder whose box holds
-- it (Restrict), so nothing behind a nearer model is ever drawn over it. Mark lines in front of a model are copied
-- the same way. Each occluder gets two copy frames over the scene (128 places: the copied pieces' places in the
-- room's order, nearest kept first).
-- (One function of its own: its locals do not count against the main chunk's 200.)
do
local function InstallCopies()
    local OCC_SLOTS, COPY_TEX_MAX, KEYS_MAX, G_MIN, PHI_EPS, FOOT = 16, 600, 128, 0.5, 1e-6, 0.1
    local huge, min = math.huge, math.min

    -- the camera of this pass (CAMT, from BeginFrame) and the scene's size
    local cex, cey, cez, cFx, cFy, cFz, cRx, cRy, cUx, cUy, cUz = 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1
    local ccx, ccy, cexx, cexy, ceyx, ceyy, cW, cH = 0, 0, 1, 0, 0, 1, 0, 0
    local function LoadCam()
        local C = CAMT
        if not C.ex then return false end
        cex, cey, cez, cFx, cFy, cFz = C.ex, C.ey, C.ez, C.Fx, C.Fy, C.Fz
        cRx, cRy, cUx, cUy, cUz = C.Rx, C.Ry, C.Ux, C.Uy, C.Uz
        ccx, ccy, cexx, cexy, ceyx, ceyy, cW, cH = C.cx, C.cy, C.exx, C.exy, C.eyx, C.eyy, C.W, C.H
        return true
    end

    -- an arena point -> screen x, y (nil behind the camera) and its depth
    local function Proj(x, y, z)
        local dx, dy, dz = x - cex, y - cey, z - cez
        local d = dx * cFx + dy * cFy + dz * cFz
        if d <= 1e-6 then return nil, nil, d end
        local r, u = dx * cRx + dy * cRy, dx * cUx + dy * cUy + dz * cUz
        return ccx + (r * cexx + u * ceyx) / d, ccy + (r * cexy + u * ceyy) / d, d
    end

    -- The occluders of this frame (1..nOcc): the UI's record, family (1 A, 2 B, 3 skip), the plane as
    -- phi * w = a Xw + b Yw + e w + k (w = 1 / depth, Xw = X w, Yw = Y w: affine on the screen over any flat piece),
    -- the screen box (clamped to the view) and whether it is on screen, the slot, and how many copies it got.
    local OIN, OFAM, OPA, OPB, OPE, OPK = {}, {}, {}, {}, {}, {}
    local OX0, OY0, OX1, OY1, OON, OSLOT, OCNT = {}, {}, {}, {}, {}, {}, {}
    local OZT = {}                               -- its feet's height (+ FOOT), false with the camera not above it
    -- Where an occluder restricts the others' copies (spec 5.13.5): its body as the screen sees it - the upright
    -- rectangle through its axis, w wide, from its feet to h (the plates' and render_check's body; no effects, no
    -- model box, no margins: a bigger region would let whoever stands behind it show through the walls around it),
    -- widened by RW px. 4 half-planes a x + b y + c >= 0 (12 numbers in ORQ) and their bounding box. Family B and
    -- skip use their box.
    local ORQ, RX0, RY0, RX1, RY1 = {}, {}, {}, {}, {}
    local RW = 0.25
    local nOcc, occChanged = 0, false
    local PREV = {}                              -- per index: last id, x, y, z and box (what changed)
    -- Per index the inputs it was derived from (id, x, y, z, h, w, rb, top and the camera's stamp: a still occluder
    -- under a still camera derives nothing again), and its restricting region's box when its last change was taken
    -- (LASTR). This frame's changes: CHG[1 .. nChg] the indices, CB their region's box before (4 numbers each).
    -- occAll: a change that concerns every slot (how many there are, an index holding another unit).
    local OSIG, LASTR, CHG, CB, nChg, occAll = {}, {}, {}, {}, 0, false
    local FAMNAME = { "A", "B", "skip" }
    local PCX, PCY, PCZ, PCD = {}, {}, {}, {}    -- the prism's 8 corners (0..7) and their depths
    local PE = { 0, 1, 1, 3, 3, 2, 2, 0, 4, 5, 5, 7, 7, 6, 6, 4, 0, 4, 1, 5, 2, 6, 3, 7 }    -- its 12 edges

    -- the restricting region of occluder i from its corners (screen; counter-clockwise or not) or its box
    local function SetRegion(i, x1, y1, x2, y2, x3, y3, x4, y4)
        local o = i * 12 - 12
        local s = (x2 - x1) * (y3 - y1) - (y2 - y1) * (x3 - x1)          -- winding: the inside is to the left if > 0
        local sg = (s >= 0) and 1 or -1
        local px, py = x4, y4
        local bx0, by0, bx1, by1 = huge, huge, -huge, -huge
        for e = 1, 4 do
            local qx = (e == 1 and x1) or (e == 2 and x2) or (e == 3 and x3) or x4
            local qy = (e == 1 and y1) or (e == 2 and y2) or (e == 3 and y3) or y4
            local ex_, ey_ = qx - px, qy - py
            local len = sqrt(ex_ * ex_ + ey_ * ey_)
            local a, b = 0, 0
            if len > 1e-9 then a, b = -ey_ * sg / len, ex_ * sg / len end   -- unit inward normal
            ORQ[o + e * 3 - 2], ORQ[o + e * 3 - 1], ORQ[o + e * 3] = a, b, -(a * px + b * py) + RW
            if qx < bx0 then bx0 = qx end
            if qx > bx1 then bx1 = qx end
            if qy < by0 then by0 = qy end
            if qy > by1 then by1 = qy end
            px, py = qx, qy
        end
        RX0[i], RY0[i], RX1[i], RY1[i] = bx0 - RW, by0 - RW, bx1 + RW, by1 + RW
    end

    -- Occluder i (its record o) for the camera of this pass: family, plane, box and restricting region; when that
    -- changed (past 0.01 yd or 0.25 px), it goes on this frame's list of changes (CHG, CB) with its region before.
    local function Derive(i, o)
        local ax, ay, az = o.x, o.y, o.z
        local R = max((o.w or 1.2) / 2, o.rb or 0) + 0.3
        local T = max(o.h or 2.6, o.top or 0) + 0.3
        local hx, hy = ax - cex, ay - cey
        local hd = sqrt(hx * hx + hy * hy)
        local nx, ny = 1, 0
        if hd > 1e-6 then
            nx, ny = hx / hd, hy / hd
        else
            local f = sqrt(cFx * cFx + cFy * cFy)
            if f > 1e-6 then nx, ny = cFx / f, cFy / f end
        end
        local lx, ly = -ny, nx
        -- the prism around it: A +- R l +- R n, at its feet and T higher
        local dmin, behind, front = huge, false, false
        local x0, y0, x1, y1, top = huge, huge, -huge, -huge, -huge
        for c = 0, 7 do
            local sl = (c % 2 == 0) and R or -R
            local sn = (c % 4 < 2) and R or -R
            local px, py, pz = ax + sl * lx + sn * nx, ay + sl * ly + sn * ny, (c < 4) and az or (az + T)
            local sx, sy, d = Proj(px, py, pz)
            PCX[c], PCY[c], PCZ[c], PCD[c] = px, py, pz, d
            if d < dmin then dmin = d end
            if d <= NEAR or not sx then
                behind = true
            else
                front = true
                if sx < x0 then x0 = sx end
                if sx > x1 then x1 = sx end
                if sy < y0 then y0 = sy end
                if sy > y1 then y1 = sy end
                if c >= 4 and sy > top then top = sy end
            end
        end
        if behind and front then
            -- through the near plane: where its edges cross it belongs to what is on screen too
            for e = 1, 12 do
                local ci, cj = PE[e * 2 - 1], PE[e * 2]
                local di, dj = PCD[ci], PCD[cj]
                if (di > NEAR) ~= (dj > NEAR) then
                    local t = (NEAR + 1e-3 - di) / (dj - di)
                    local sx, sy = Proj(PCX[ci] + (PCX[cj] - PCX[ci]) * t, PCY[ci] + (PCY[cj] - PCY[ci]) * t,
                        PCZ[ci] + (PCZ[cj] - PCZ[ci]) * t)
                    if sx then
                        if sx < x0 then x0 = sx end
                        if sx > x1 then x1 = sx end
                        if sy < y0 then y0 = sy end
                        if sy > y1 then y1 = sy end
                    end
                end
            end
        end
        -- Its feet: with the camera above them, nothing lower than its feet (+ FOOT) can be in front of any of it
        -- along a ray from the eye (the ray to a point of it stays above that height), so its copies, and the
        -- copies over it, keep only what lies higher: the floor it stands on is never drawn over it. A half-space
        -- holding the eye, like its plane: the copies stay a prefix of every ray (spec 5.13.6).
        local zt = az + FOOT
        OZT[i] = (cez > zt + 0.05) and zt or false
        local fam
        if hd >= G_MIN and not behind then
            -- family A: the plane through its axis facing the camera; the box from the prism's sides (+2 px) up
            -- to its top (+2 px) and down to the prism's bottom (with the camera at or under its feet: down to its
            -- feet at the axis's depth, the floor in front of them lying lower on the screen)
            fam = 1
            local bot = y0 - 2
            if not OZT[i] then
                bot = huge
                for s = -1, 1 do
                    local _, sy = Proj(ax + s * R * lx, ay + s * R * ly, az)
                    if sy and sy - 2 < bot then bot = sy - 2 end           -- (+2 px, as the other sides)
                end
            end
            x0, x1, y0, y1 = x0 - 2, x1 + 2, bot, top + 2
            -- (phi + PHI_EPS < 0: what lies in the plane itself - a mark's column through its axis, a beam that
            -- starts there - is inside the model and stays under it, whatever the rounding)
            OPA[i], OPB[i], OPE[i], OPK[i] = nx, ny, -(nx * ax + ny * ay) + PHI_EPS, 0
        else
            -- family B: only what is nearer than every corner of the prism; skip when that reaches the near plane.
            -- Its box: what of the prism is in front of the near plane (nothing when all of it is behind)
            dmin = dmin - 0.05
            if not front then x0, y0, x1, y1 = 0, 0, -1, -1 end
            if dmin <= NEAR then
                fam = 3
                OPA[i], OPB[i], OPE[i], OPK[i] = 0, 0, 0, 1          -- (phi = +1: nothing on its near side)
            else
                fam = 2
                OPA[i], OPB[i], OPE[i], OPK[i] = 0, 0, -dmin, 1
            end
        end
        if x0 < 0 then x0 = 0 end
        if y0 < 0 then y0 = 0 end
        if x1 > cW then x1 = cW end
        if y1 > cH then y1 = cH end
        OFAM[i], OX0[i], OY0[i], OX1[i], OY1[i], OON[i] = fam, x0, y0, x1, y1, (x0 < x1 and y0 < y1)
        if fam == 1 then
            local r, h = (o.w or 1.2) / 2, o.h or 2.6                    -- (inside the prism: all in front)
            local sx1, sy1 = Proj(ax - r * lx, ay - r * ly, az)
            local sx2, sy2 = Proj(ax + r * lx, ay + r * ly, az)
            local sx3, sy3 = Proj(ax + r * lx, ay + r * ly, az + h)
            local sx4, sy4 = Proj(ax - r * lx, ay - r * ly, az + h)
            SetRegion(i, sx1, sy1, sx2, sy2, sx3, sy3, sx4, sy4)
        else
            SetRegion(i, x0, y0, x1, y0, x1, y1, x0, y1)
        end
        local q, P = i * 8 - 8, PREV
        if P[q + 1] ~= o.id or abs(P[q + 2] - ax) > 0.01 or abs(P[q + 3] - ay) > 0.01 or abs(P[q + 4] - az) > 0.01
            or abs(P[q + 5] - x0) > 0.25 or abs(P[q + 6] - y0) > 0.25 or abs(P[q + 7] - x1) > 0.25
            or abs(P[q + 8] - y1) > 0.25 then
            occChanged = true
            if P[q + 1] ~= o.id then occAll = true end
            P[q + 1], P[q + 2], P[q + 3], P[q + 4], P[q + 5], P[q + 6], P[q + 7], P[q + 8] = o.id, ax, ay, az, x0, y0,
                x1, y1
            nChg = nChg + 1
            CHG[nChg] = i
            local c, r, L = nChg * 4 - 4, i * 4 - 4, LASTR
            CB[c + 1], CB[c + 2] = L[r + 1] or huge, L[r + 2] or huge
            CB[c + 3], CB[c + 4] = L[r + 3] or -huge, L[r + 4] or -huge
            L[r + 1], L[r + 2], L[r + 3], L[r + 4] = RX0[i], RY0[i], RX1[i], RY1[i]
        end
    end

    -- list[1..n]: { id, x, y, z (arena: the model's feet), h, w (yd), rb, top (the model's own box: radius and
    -- height; 0 when unknown), prio (2 for you) }. Derives family, plane and box for the camera BeginFrame measured
    -- (again only for an occluder whose inputs or camera changed).
    function Room.SetOccluders(list, n)
        n = n or #list
        nChg = 0
        if not (meshOk and haveBasis and LoadCam()) then
            if nOcc ~= 0 then occChanged, occAll = true, true end
            nOcc = 0
            return
        end
        if n ~= nOcc then occChanged, occAll = true, true end
        nOcc = n
        local cs, S = CAMT.stamp, OSIG
        for i = 1, n do
            local o = list[i]
            OIN[i] = o
            local g = i * 9 - 9
            if not (S[g + 1] == o.id and S[g + 2] == o.x and S[g + 3] == o.y and S[g + 4] == o.z and S[g + 5] == o.h
                and S[g + 6] == o.w and S[g + 7] == o.rb and S[g + 8] == o.top and S[g + 9] == cs) then
                S[g + 1], S[g + 2], S[g + 3], S[g + 4], S[g + 5] = o.id, o.x, o.y, o.z, o.h
                S[g + 6], S[g + 7], S[g + 8], S[g + 9] = o.w, o.rb, o.top, cs
                Derive(i, o)
            end
        end
    end

    -- Slots: up to OCC_SLOTS occluders on screen (not skip) get copies, you first, then the biggest boxes; one keeps
    -- its slot from the last frame.
    local slotOf, SLOTOCC, ORDER = {}, {}, {}
    local function SlotCmp(a, b)
        local pa, pb = OIN[a].prio or 1, OIN[b].prio or 1
        if pa ~= pb then return pa > pb end
        local sa, sb = (OX1[a] - OX0[a]) * (OY1[a] - OY0[a]), (OX1[b] - OX0[b]) * (OY1[b] - OY0[b])
        if sa ~= sb then return sa > sb end
        return a < b
    end
    local function AssignSlots()
        local n = 0
        for i = 1, nOcc do
            OSLOT[i], OCNT[i] = -1, 0
            if OON[i] and OFAM[i] ~= 3 then
                n = n + 1
                ORDER[n] = i
            end
        end
        for i = n + 1, #ORDER do ORDER[i] = nil end
        if n > 1 then table.sort(ORDER, SlotCmp) end
        if n > OCC_SLOTS then
            for i = OCC_SLOTS + 1, n do ORDER[i] = nil end
            n = OCC_SLOTS
        end
        for j = 0, OCC_SLOTS - 1 do SLOTOCC[j] = false end
        for k = 1, n do
            local i = ORDER[k]
            local j = slotOf[OIN[i].id]
            if j and not SLOTOCC[j] then SLOTOCC[j], OSLOT[i] = i, j end
        end
        local free = 0
        for k = 1, n do
            local i = ORDER[k]
            if OSLOT[i] < 0 then
                while SLOTOCC[free] do free = free + 1 end
                SLOTOCC[free], OSLOT[i] = i, free
            end
        end
        wipe(slotOf)
        for k = 1, n do slotOf[OIN[ORDER[k]].id] = OSLOT[ORDER[k]] end
    end

    -- Polygons: screen points only (x, y: 2 numbers per corner), in reusable buffers. Over one GPU triangle of a piece
    -- every other value the copies need - u, v as its texture shows them (the GPU's own interpolation), w = 1 / depth,
    -- X w, Y w, Z w (a flat triangle through a pinhole camera) - is an affine function of the screen point, so every
    -- cut is a half-plane of the screen (exact) and those values are worked out only where they are used (TA).
    -- Clip keeps the part where A x + B y + C >= 0: src (m corners) -> dst, its corner count.
    local BUFS = {}
    local function Buf(i)
        local b = BUFS[i]
        if not b then
            b = {}
            BUFS[i] = b
        end
        return b
    end
    local function Clip(src, m, dst, A, B, C)
        local n, po = 0, m * 2 - 2
        local px, py = src[po + 1], src[po + 2]
        local pf = A * px + B * py + C
        for q = 0, m * 2 - 2, 2 do
            local x, y = src[q + 1], src[q + 2]
            local f = A * x + B * y + C
            if (f >= 0) ~= (pf >= 0) then
                local t, d = pf / (pf - f), n * 2
                dst[d + 1], dst[d + 2] = px + (x - px) * t, py + (y - py) * t
                n = n + 1
            end
            if f >= 0 then
                local d = n * 2
                dst[d + 1], dst[d + 2] = x, y
                n = n + 1
            end
            px, py, pf = x, y, f
        end
        return n
    end

    -- The GPU triangle being copied. TA: per value A its function A = Ax x + Ay y + A0 (3 numbers): u 1..3, v 4..6
    -- (Setup), w 7..9, X w 10..12, Y w 13..15, Z w 16..18 (SetupW, once a cut needs them: taW); its corners 19, 20,
    -- 27; its first corner's screen point 21, 22, the edges to the others 23..26 and 1 / det 28.
    local TA, taW = {}, false
    -- the function through values A1, A2, A3 at the corners -> TA[o + 1 .. o + 3]
    local function Affine(o, A1, A2, A3)
        local T = TA
        local d2, d3, r = A2 - A1, A3 - A1, T[28]
        local gx, gy = (d2 * T[26] - d3 * T[24]) * r, (d3 * T[23] - d2 * T[25]) * r
        T[o + 1], T[o + 2], T[o + 3] = gx, gy, A1 - gx * T[21] - gy * T[22]
    end
    -- Corners i1, i2, i3 into polygon P (3 corners) and TA's u, v. -> false when the triangle covers under 1 px^2
    -- (nothing of it would show: Fan drops anything that small)
    local function Setup(P, i1, i2, i3)
        local x1, y1, x2, y2, x3, y3 = PX[i1], PY[i1], PX[i2], PY[i2], PX[i3], PY[i3]
        local ax, ay, bx, by = x2 - x1, y2 - y1, x3 - x1, y3 - y1
        local det = ax * by - bx * ay
        if det < 2 and det > -2 then return false end
        P[1], P[2], P[3], P[4], P[5], P[6] = x1, y1, x2, y2, x3, y3
        local r, T = 1 / det, TA
        T[19], T[20], T[27], T[21], T[22], T[23], T[24], T[25], T[26], T[28] = i1, i2, i3, x1, y1, ax, ay, bx, by, r
        local A1 = DU[i1]
        local d2, d3 = DU[i2] - A1, DU[i3] - A1
        local gx, gy = (d2 * by - d3 * ay) * r, (d3 * ax - d2 * bx) * r
        T[1], T[2], T[3] = gx, gy, A1 - gx * x1 - gy * y1
        A1 = DV[i1]
        d2, d3 = DV[i2] - A1, DV[i3] - A1
        gx, gy = (d2 * by - d3 * ay) * r, (d3 * ax - d2 * bx) * r
        T[4], T[5], T[6] = gx, gy, A1 - gx * x1 - gy * y1
        taW = false
        return true
    end
    local function SetupW()
        local T = TA
        local i1, i2, i3 = T[19], T[20], T[27]
        local w1, w2, w3 = 1 / PD[i1], 1 / PD[i2], 1 / PD[i3]
        Affine(6, w1, w2, w3)
        Affine(9, WX[i1] * w1, WX[i2] * w2, WX[i3] * w3)
        Affine(12, WY[i1] * w1, WY[i2] * w2, WY[i3] * w3)
        Affine(15, WZ[i1] * w1, WZ[i2] * w2, WZ[i3] * w3)
        taW = true
    end

    -- An occluder's near side (phi < 0: phi w = a X w + b Y w + e w + k < 0) and, when the camera is above its feet,
    -- the part higher than them (Z w - zt w > 0), over the current triangle: src (m corners) -> into buffer a (b:
    -- scratch) -> the buffer holding it, its corner count.
    local function NearSide(N, src, m, a, b)
        if not taW then SetupW() end
        local T = TA
        local pa, pb, pe, pk, zt = OPA[N], OPB[N], OPE[N], OPK[N], OZT[N]
        local gx, gy = pa * T[10] + pb * T[13] + pe * T[7], pa * T[11] + pb * T[14] + pe * T[8]
        local g0 = pa * T[12] + pb * T[15] + pe * T[9] + pk
        local hx, hy, h0 = 0, 0, 0
        if zt then hx, hy, h0 = T[16] - zt * T[7], T[17] - zt * T[8], T[18] - zt * T[9] end
        local allIn = true                             -- (all of it on the near side: nothing to cut)
        for v = 0, m * 2 - 2, 2 do
            local x, y = src[v + 1], src[v + 2]
            if gx * x + gy * y + g0 >= 0 or (zt and hx * x + hy * y + h0 <= 0) then
                allIn = false
                break
            end
        end
        if allIn then return src, m end
        m = Clip(src, m, a, -gx, -gy, -g0)
        if not zt or m < 3 then return a, m end
        return b, Clip(a, m, b, hx, hy, h0)
    end

    -- The part of src (m corners) inside the rectangle, using buffers ba / bb (never writing into src) -> the
    -- buffer that holds it (src itself when it lies inside already) and its corner count (0: nothing inside).
    local function ClipRect(src, m, x0, y0, x1, y1, ba, bb)
        local px0, py0, px1, py1 = huge, huge, -huge, -huge
        for q = 0, m * 2 - 2, 2 do
            local x, y = src[q + 1], src[q + 2]
            if x < px0 then px0 = x end
            if x > px1 then px1 = x end
            if y < py0 then py0 = y end
            if y > py1 then py1 = y end
        end
        if px1 <= x0 or px0 >= x1 or py1 <= y0 or py0 >= y1 then return src, 0 end
        local cur, out = src, ba
        if px0 < x0 then
            m = Clip(cur, m, out, 1, 0, -x0)
            cur, out = out, (out == ba) and bb or ba
            if m < 3 then return cur, 0 end
        end
        if px1 > x1 then
            m = Clip(cur, m, out, -1, 0, x1)
            cur, out = out, (out == ba) and bb or ba
            if m < 3 then return cur, 0 end
        end
        if py0 < y0 then
            m = Clip(cur, m, out, 0, 1, -y0)
            cur, out = out, (out == ba) and bb or ba
            if m < 3 then return cur, 0 end
        end
        if py1 > y1 then
            m = Clip(cur, m, out, 0, -1, y1)
            cur = out
            if m < 3 then return cur, 0 end
        end
        return cur, m
    end

    -- Copy items of this pass: key (the piece's place in the room's order), kind (1 a texture: pool, light, 16
    -- numbers = x, y, u, v of UL, LL, UR, LR; 2 a line: x1, y1, x2, y2, r, g, b, a, thickness).
    local IK, ITY, IP, IL, IV = {}, {}, {}, {}, {}
    local nItems = 0
    local curKey, curPool, curLight = 0, 0, 1

    -- A fragment (b, m corners) -> texture items: a fan of quads (v1, vi, vi+1, vi+2) and a last triangle. A quad's
    -- corners go UL = v1, LL = vi, LR = vi+1, UR = vi+2; a triangle's UR and LR are both its last corner. All lie in
    -- one GPU triangle of the piece, with its texture coordinates, so either diagonal shows the same picture.
    local function Fan(b, m)
        local s, q = 0, m * 2 - 2
        local px, py = b[q + 1], b[q + 2]
        for o = 0, m * 2 - 2, 2 do
            local x, y = b[o + 1], b[o + 2]
            s = s + (px * y - x * py)
            px, py = x, y
        end
        if abs(s) < 2 then return end                                -- (under 1 px^2)
        local T = TA
        local ux, uy, u0, vx, vy, v0 = T[1], T[2], T[3], T[4], T[5], T[6]
        local x1, y1 = b[1], b[2]
        local U1, V1 = ux * x1 + uy * y1 + u0, vx * x1 + vy * y1 + v0
        local i = 2
        while i + 1 <= m do
            nItems = nItems + 1
            local it = nItems
            IK[it], ITY[it], IP[it], IL[it] = curKey, 1, curPool, curLight
            local o = it * 16 - 16
            local qb, qc = (i - 1) * 2, i * 2                         -- vi, vi+1
            local qd = qc                                             -- UR: vi+2 for a quad, vi+1 for a triangle
            if i + 2 <= m then qd = (i + 1) * 2 end
            local xb, yb, xc, yc, xd, yd = b[qb + 1], b[qb + 2], b[qc + 1], b[qc + 2], b[qd + 1], b[qd + 2]
            -- UL, LL, UR, LR: x, y, u, v
            IV[o + 1], IV[o + 2], IV[o + 3], IV[o + 4] = x1, y1, U1, V1
            IV[o + 5], IV[o + 6], IV[o + 7], IV[o + 8] = xb, yb, ux * xb + uy * yb + u0, vx * xb + vy * yb + v0
            IV[o + 9], IV[o + 10], IV[o + 11], IV[o + 12] = xd, yd, ux * xd + uy * yd + u0, vx * xd + vy * yd + v0
            IV[o + 13], IV[o + 14], IV[o + 15], IV[o + 16] = xc, yc, ux * xc + uy * yc + u0, vx * xc + vy * yc + v0
            i = i + ((i + 2 <= m) and 2 or 1)
        end
    end

    -- The other occluders a fragment of X's copies must respect (OVL: those whose restricting region overlaps X's
    -- box), the ones overlapping the fragment, largest overlap first: OTH[1..nOth].
    local OVL, nOvl, OTH, OTHA, nOth = {}, 0, {}, {}, 0
    local function Others(x0, y0, x1, y1)
        nOth = 0
        for v = 1, nOvl do
            local N = OVL[v]
            local w = min(x1, RX1[N]) - max(x0, RX0[N])
            local h = min(y1, RY1[N]) - max(y0, RY0[N])
            if w > 0 and h > 0 then
                local ar, j = w * h, nOth
                while j > 0 and OTHA[j] < ar do
                    OTH[j + 1], OTHA[j + 1] = OTH[j], OTHA[j]
                    j = j - 1
                end
                OTH[j + 1], OTHA[j + 1] = N, ar
                nOth = nOth + 1
            end
        end
    end

    -- Restrict (spec 5.13.5): at every pixel a copy lies on the near side of each other occluder whose restricting
    -- region holds it. For the EXACT largest overlaps the fragment is split exactly: its part inside N's region is cut
    -- to N's near side, the parts outside it (frag in edges 1..i-1, out of edge i: disjoint) stay as they are; any
    -- further N cuts it everywhere (on the safe side). Level lvl owns buffers 4 lvl .. 4 lvl + 3.
    local EXACT = 4
    local Restrict
    Restrict = function(b, m, lvl)
        if lvl > nOth then
            Fan(b, m)
            return
        end
        local N = OTH[lvl]
        local ca, cb, pc, pd = Buf(4 * lvl), Buf(4 * lvl + 1), Buf(4 * lvl + 2), Buf(4 * lvl + 3)
        if lvl > EXACT then
            local c, mm = NearSide(N, b, m, pc, pd)
            if mm >= 3 then Restrict(c, mm, lvl + 1) end
            return
        end
        local o, cur, out = N * 12 - 12, b, ca
        for i = 1, 4 do
            local qa, qb, qc = ORQ[o + i * 3 - 2], ORQ[o + i * 3 - 1], ORQ[o + i * 3]
            local fin, fout = false, false                              -- (corners inside / outside edge i)
            for v = 0, m * 2 - 2, 2 do
                if qa * cur[v + 1] + qb * cur[v + 2] + qc >= 0 then fin = true else fout = true end
            end
            if not fin then                                             -- all of it outside N's region
                Restrict(cur, m, lvl + 1)
                return
            end
            if fout then
                local mm = Clip(cur, m, pc, -qa, -qb, -qc)               -- outside edge i: not N's
                if mm >= 3 then Restrict(pc, mm, lvl + 1) end
                m = Clip(cur, m, out, qa, qb, qc)                        -- inside it: on to the next edge
                if m < 3 then return end
                cur, out = out, (out == ca) and cb or ca
            end
        end
        local c, mm = NearSide(N, cur, m, pc, pd)                       -- inside N's region: N's near side only
        if mm >= 3 then Restrict(c, mm, lvl + 1) end
    end

    -- the leaves' screen bins (after each redraw; their screen boxes are in LR, from Emit), and per slot the leaves
    -- whose box overlaps its occluder's
    local leafStamp = -1
    local binX0, binY0, binX1, binY1 = 0, 0, 0, 0             -- (the union of the slots' boxes the bins were made for)
    local GX, GY, GRID, GN = 16, 12, {}, {}
    for c = 0, GX * GY - 1 do GRID[c], GN[c] = {}, 0 end
    local BIG, nBig = {}, 0                                   -- leaves over more than 4 cells
    local SEEN, seenStamp = {}, 0
    local CAND, NC = {}, {}
    for j = 0, OCC_SLOTS - 1 do CAND[j], NC[j] = {}, 0 end
    local ibx0, iby0, ibx1, iby1 = 0, 0, 0, 0                 -- the box of this slot's fragments before Restrict

    -- X's copies of the room pieces: every leaf in its box with a corner on its near side (and above its feet), each
    -- of its GPU triangles (UL, LL, UR; a quad also LL, LR, UR, the LL - UR split) clipped to the box and the near
    -- side (not needed when its three corners lie there: all of it does), then restricted by the others.
    local function CopyLeaves(X, list, n)
        local a, b, e, k, zt = OPA[X], OPB[X], OPE[X], OPK[X], OZT[X]
        local bx0, by0, bx1, by1 = OX0[X], OY0[X], OX1[X], OY1[X]
        local P, B2, B3, B4 = Buf(1), Buf(2), Buf(3), Buf(0)
        for ii = 1, n do
            local i = list[ii]
            local q = i * 12 - 12
            local p, key, cn = LR[q + 1], LR[q + 2], LR[q + 3]
            if live[key] then
                local c1, c2, c3, c4 = LR[q + 4], LR[q + 5], LR[q + 6], LR[q + 7]
                local f1 = (a * WX[c1] + b * WY[c1] + e) / PD[c1] + k < 0
                local f2 = (a * WX[c2] + b * WY[c2] + e) / PD[c2] + k < 0
                local f3 = (a * WX[c3] + b * WY[c3] + e) / PD[c3] + k < 0
                local f4 = (a * WX[c4] + b * WY[c4] + e) / PD[c4] + k < 0
                local h1, h2, h3, h4 = true, true, true, true
                if zt then h1, h2, h3, h4 = WZ[c1] > zt, WZ[c2] > zt, WZ[c3] > zt, WZ[c4] > zt end
                if (f1 or f2 or f3 or f4) and (h1 or h2 or h3 or h4) then
                    curKey, curPool, curLight = 2 * rankOf[QN[p]], QPOOL[p], QL[p]
                    local inside = LR[q + 9] >= bx0 and LR[q + 11] <= bx1 and LR[q + 10] >= by0 and LR[q + 12] <= by1
                    f1, f2, f3, f4 = f1 and h1, f2 and h2, f3 and h3, f4 and h4      -- (the corner is on the near side)
                    for t = 1, (cn == 4) and 2 or 1 do
                        local ok, near
                        if t == 1 then                              -- UL (c1), LL (c2), UR (c4)
                            ok, near = Setup(P, c1, c2, c4), f1 and f2 and f4
                        else                                        -- LL (c2), LR (c3), UR (c4)
                            ok, near = Setup(P, c2, c3, c4), f2 and f3 and f4
                        end
                        if ok then
                            local src, m = P, 3
                            if not inside then src, m = ClipRect(P, 3, bx0, by0, bx1, by1, B2, B3) end
                            if m >= 3 and not near then
                                if src == B2 then src, m = NearSide(X, src, m, B3, B4)
                                else src, m = NearSide(X, src, m, B2, B4) end
                            end
                            if m >= 3 then
                                local fx0, fy0, fx1, fy1 = huge, huge, -huge, -huge
                                for o = 0, m * 2 - 2, 2 do
                                    local x, y = src[o + 1], src[o + 2]
                                    if x < fx0 then fx0 = x end
                                    if x > fx1 then fx1 = x end
                                    if y < fy0 then fy0 = y end
                                    if y > fy1 then fy1 = y end
                                end
                                if fx0 < ibx0 then ibx0 = fx0 end
                                if fy0 < iby0 then iby0 = fy0 end
                                if fx1 > ibx1 then ibx1 = fx1 end
                                if fy1 > iby1 then iby1 = fy1 end
                                if nOvl > 0 then Others(fx0, fy0, fx1, fy1) else nOth = 0 end
                                Restrict(src, m, 1)
                            end
                        end
                    end
                end
            end
        end
    end

    -- Mark lines: a placed segment A + t (B - A), 0 <= t <= 1 (arena; in front of the near plane). Every test is
    -- linear in t (the screen box multiplied out by the depth), so its copies are intervals of t.
    local sax, say, saz, sbx, sby, sbz = 0, 0, 0, 0, 0, 0
    local sdA, srA, suA, sdB, srB, suB = 0, 0, 0, 0, 0, 0
    local lr, lg, lb, la, lt, lkey = 1, 1, 1, 1, 1, 0
    local function Cut(lo, hi, g0, g1)                -- the part of [lo, hi] where g0 + t (g1 - g0) >= 0, or nil
        local gl, gh = g0 + (g1 - g0) * lo, g0 + (g1 - g0) * hi
        if gl >= 0 and gh >= 0 then return lo, hi end
        if gl < 0 and gh < 0 then return nil end
        local t = g0 / (g0 - g1)
        if gl < 0 then return t, hi end
        return lo, t
    end
    local function CutBox(lo, hi, x0, y0, x1, y1)
        lo, hi = Cut(lo, hi, (ccx - x0) * sdA + cexx * srA + ceyx * suA, (ccx - x0) * sdB + cexx * srB + ceyx * suB)
        if not lo then return nil end
        lo, hi = Cut(lo, hi, (x1 - ccx) * sdA - cexx * srA - ceyx * suA, (x1 - ccx) * sdB - cexx * srB - ceyx * suB)
        if not lo then return nil end
        lo, hi = Cut(lo, hi, (ccy - y0) * sdA + cexy * srA + ceyy * suA, (ccy - y0) * sdB + cexy * srB + ceyy * suB)
        if not lo then return nil end
        return Cut(lo, hi, (y1 - ccy) * sdA - cexy * srA - ceyy * suA, (y1 - ccy) * sdB - cexy * srB - ceyy * suB)
    end
    local function CutPhi(lo, hi, N)                  -- N's near side: phi < 0 (phi = a X + b Y + e + k d), above its feet
        local a, b, e, k = OPA[N], OPB[N], OPE[N], OPK[N]
        lo, hi = Cut(lo, hi, -(a * sax + b * say + e + k * sdA), -(a * sbx + b * sby + e + k * sdB))
        local zt = OZT[N]
        if not (lo and zt) then return lo, hi end
        return Cut(lo, hi, saz - zt, sbz - zt)
    end
    local function EmitLine(t0, t1)
        local x1, y1 = Proj(sax + (sbx - sax) * t0, say + (sby - say) * t0, saz + (sbz - saz) * t0)
        local x2, y2 = Proj(sax + (sbx - sax) * t1, say + (sby - say) * t1, saz + (sbz - saz) * t1)
        if not (x1 and x2) or (x2 - x1) ^ 2 + (y2 - y1) ^ 2 < 0.09 then return end
        nItems = nItems + 1
        local it = nItems
        IK[it], ITY[it] = lkey, 2
        local o = it * 16 - 16
        IV[o + 1], IV[o + 2], IV[o + 3], IV[o + 4], IV[o + 5] = x1, y1, x2, y2, lr
        IV[o + 6], IV[o + 7], IV[o + 8], IV[o + 9] = lg, lb, la, lt
    end
    local function CutRegion(lo, hi, N)                -- the part of [lo, hi] inside N's restricting region, or nil
        local o = N * 12 - 12
        for i = 1, 4 do
            local qa, qb, qc = ORQ[o + i * 3 - 2], ORQ[o + i * 3 - 1], ORQ[o + i * 3]
            -- a x + b y + c >= 0, x = cx + (r exx + u eyx) / d, y = cy + (r exy + u eyy) / d, times d > 0
            local kd, kr, ku = qa * ccx + qb * ccy + qc, qa * cexx + qb * cexy, qa * ceyx + qb * ceyy
            lo, hi = Cut(lo, hi, kd * sdA + kr * srA + ku * suA, kd * sdB + kr * srB + ku * suB)
            if not lo then return nil end
        end
        return lo, hi
    end
    local RestrictT
    RestrictT = function(lo, hi, lvl)
        if lvl > nOth then
            EmitLine(lo, hi)
            return
        end
        local N = OTH[lvl]
        if lvl > EXACT then
            local a, b = CutPhi(lo, hi, N)
            if a then RestrictT(a, b, lvl + 1) end
            return
        end
        local b0, b1 = CutRegion(lo, hi, N)
        if not b0 then
            RestrictT(lo, hi, lvl + 1)
            return
        end
        local a, b = CutPhi(b0, b1, N)
        if a then RestrictT(a, b, lvl + 1) end
        if b0 > lo then RestrictT(lo, b0, lvl + 1) end
        if b1 < hi then RestrictT(b1, hi, lvl + 1) end
    end
    local function CopyLines(X)
        local R = MKR
        local RS, RA, RC, RK = R.S, R.A, R.C, R.K
        local bx0, by0, bx1, by1 = OX0[X], OY0[X], OX1[X], OY1[X]
        for j = 1, R.n do
            local q = j * 4 - 4
            local x1, y1, x2, y2 = RS[q + 1], RS[q + 2], RS[q + 3], RS[q + 4]
            local th = RC[j * 5]
            local mx0, mx1 = min(x1, x2) - th, max(x1, x2) + th
            local my0, my1 = min(y1, y2) - th, max(y1, y2) + th
            if mx1 >= bx0 and mx0 <= bx1 and my1 >= by0 and my0 <= by1 then
                q = j * 6 - 6
                sax, say, saz, sbx, sby, sbz = RA[q + 1], RA[q + 2], RA[q + 3], RA[q + 4], RA[q + 5], RA[q + 6]
                local dx, dy, dz = sax - cex, say - cey, saz - cez
                sdA, srA, suA = dx * cFx + dy * cFy + dz * cFz, dx * cRx + dy * cRy, dx * cUx + dy * cUy + dz * cUz
                dx, dy, dz = sbx - cex, sby - cey, sbz - cez
                sdB, srB, suB = dx * cFx + dy * cFy + dz * cFz, dx * cRx + dy * cRy, dx * cUx + dy * cUy + dz * cUz
                local lo, hi = CutPhi(0, 1, X)
                if lo then lo, hi = CutBox(lo, hi, bx0, by0, bx1, by1) end
                if lo and hi - lo > 1e-6 then
                    if mx0 < ibx0 then ibx0 = mx0 end
                    if my0 < iby0 then iby0 = my0 end
                    if mx1 > ibx1 then ibx1 = mx1 end
                    if my1 > iby1 then iby1 = my1 end
                    q = j * 5 - 5
                    lr, lg, lb, la, lt, lkey = RC[q + 1], RC[q + 2], RC[q + 3], RC[q + 4], RC[q + 5], RK[j]
                    if nOvl > 0 then Others(mx0, my0, mx1, my1) else nOth = 0 end
                    RestrictT(lo, hi, 1)
                end
            end
        end
    end

    -- Copy frames: two per slot, at V + copy0 + 2 slot and one higher; per frame its textures by pool and its lines,
    -- with how many this pass used. Setters are cached on each texture / line.
    local CF = {}                                -- (made in order: CF[1 .. #CF] all exist)
    local function CopyFrame(fi)
        local fr = CF[fi]
        while not fr do
            local i = #CF + 1
            fr = CreateFrame("Frame", nil, view)
            fr:SetAllPoints(view)
            fr.tex, fr.used, fr.lines, fr.lineUsed, fr.lvl = {}, {}, {}, 0, -1
            CF[i] = fr
            fr = CF[fi]
        end
        local lvl = V + LVt.copy0 + fi - 1
        if fr.lvl ~= lvl then
            fr:SetFrameLevel(lvl)
            fr.lvl = lvl
        end
        return fr
    end

    local function PutTex(fr, p, it, hx, hy)
        local pool = IP[it]
        local list = fr.tex[pool]
        if not list then
            list = {}
            fr.tex[pool] = list
        end
        local n = (fr.used[pool] or 0) + 1
        fr.used[pool] = n
        local tx = list[n]
        if not tx then
            tx = fr:CreateTexture(nil, "BACKGROUND")
            tx:SetSize(1, 1)
            tx:SetPoint("CENTER", scene, "CENTER", 0, 0)
            if tx.SetSnapToPixelGrid then tx:SetSnapToPixelGrid(false) end
            if tx.SetTexelSnappingBias then tx:SetTexelSnappingBias(0) end
            tx:SetTexture(floor(pool / 4), "REPEAT", "REPEAT")
            tx:SetBlendMode(BLENDS[pool % 4])
            tx.shown, tx.pool = true, pool
            list[n] = tx
        end
        local L = IL[it]
        if tx.light ~= L then Paint(tx, L) end
        if tx.pos ~= p then
            tx:SetDrawLayer(LAYERS[floor(p / 16) + 1], p % 16 - 8)
            tx.pos = p
        end
        local o = it * 16 - 16
        local u1, v1, u2, v2 = IV[o + 3], IV[o + 4], IV[o + 7], IV[o + 8]
        local u3, v3, u4, v4 = IV[o + 11], IV[o + 12], IV[o + 15], IV[o + 16]
        if tx.u1 ~= u1 or tx.v1 ~= v1 or tx.u2 ~= u2 or tx.v2 ~= v2 or tx.u3 ~= u3 or tx.v3 ~= v3 or tx.u4 ~= u4
            or tx.v4 ~= v4 then
            tx:SetTexCoord(u1, v1, u2, v2, u3, v3, u4, v4)
            tx.u1, tx.v1, tx.u2, tx.v2, tx.u3, tx.v3, tx.u4, tx.v4 = u1, v1, u2, v2, u3, v3, u4, v4
        end
        local x, y = IV[o + 1] - hx + 0.5, IV[o + 2] - hy - 0.5                 -- (spec 4.3)
        if not tx.ox1 or abs(tx.ox1 - x) > 0.01 or abs(tx.oy1 - y) > 0.01 then
            tx:SetVertexOffset(VUL, x, y)
            tx.ox1, tx.oy1 = x, y
        end
        x, y = IV[o + 5] - hx + 0.5, IV[o + 6] - hy + 0.5
        if not tx.ox2 or abs(tx.ox2 - x) > 0.01 or abs(tx.oy2 - y) > 0.01 then
            tx:SetVertexOffset(VLL, x, y)
            tx.ox2, tx.oy2 = x, y
        end
        x, y = IV[o + 9] - hx - 0.5, IV[o + 10] - hy - 0.5
        if not tx.ox3 or abs(tx.ox3 - x) > 0.01 or abs(tx.oy3 - y) > 0.01 then
            tx:SetVertexOffset(VUR, x, y)
            tx.ox3, tx.oy3 = x, y
        end
        x, y = IV[o + 13] - hx - 0.5, IV[o + 14] - hy + 0.5
        if not tx.ox4 or abs(tx.ox4 - x) > 0.01 or abs(tx.oy4 - y) > 0.01 then
            tx:SetVertexOffset(VLR, x, y)
            tx.ox4, tx.oy4 = x, y
        end
        if not tx.shown then
            tx:Show()
            tx.shown = true
        end
    end

    local function PutLine(fr, p, it)
        local n = fr.lineUsed + 1
        fr.lineUsed = n
        local l = fr.lines[n]
        if not l then
            l = fr:CreateLine(nil, "BACKGROUND")
            if l.SetSnapToPixelGrid then l:SetSnapToPixelGrid(false) end
            if l.SetTexelSnappingBias then l:SetTexelSnappingBias(0) end
            l.shown = true
            fr.lines[n] = l
        end
        local o = it * 16 - 16
        local x1, y1, x2, y2 = IV[o + 1], IV[o + 2], IV[o + 3], IV[o + 4]
        local r, g, b, a, th = IV[o + 5], IV[o + 6], IV[o + 7], IV[o + 8], IV[o + 9]
        if l.pos ~= p then
            l:SetDrawLayer(LAYERS[floor(p / 16) + 1], p % 16 - 8)
            l.pos = p
        end
        if l.thick ~= th then
            l:SetThickness(th)
            l.thick = th
        end
        if l.cr ~= r or l.cg ~= g or l.cb ~= b or l.ca ~= a then
            l:SetColorTexture(r, g, b, a)
            l.cr, l.cg, l.cb, l.ca = r, g, b, a
        end
        if not l.x1 or abs(l.x1 - x1) > 0.01 or abs(l.y1 - y1) > 0.01 then
            l:SetStartPoint("BOTTOMLEFT", scene, x1, y1)
            l.x1, l.y1 = x1, y1
        end
        if not l.x2 or abs(l.x2 - x2) > 0.01 or abs(l.y2 - y2) > 0.01 then
            l:SetEndPoint("BOTTOMLEFT", scene, x2, y2)
            l.x2, l.y2 = x2, y2
        end
        if not l.shown then
            l:Show()
            l.shown = true
        end
    end

    -- hide what this pass did not use in copy frames f0 .. f1 (all when not given); -> copy textures shown there
    local function HideUnused(f0, f1)
        local shown = 0
        if not f1 or f1 > #CF then f1 = #CF end
        for fi = f0 or 1, f1 do
            local fr = CF[fi]
            for pool, list in pairs(fr.tex) do
                local used = fr.used[pool] or 0
                shown = shown + used
                for i = used + 1, #list do
                    local tx = list[i]
                    if tx.shown then
                        tx:Hide()
                        tx.shown = false
                    end
                end
            end
            local ls = fr.lines
            for i = fr.lineUsed + 1, #ls do
                local l = ls[i]
                if l.shown then
                    l:Hide()
                    l.shown = false
                end
            end
        end
        return shown
    end
    -- copy frames f0 .. f1 to be filled again from nothing
    local function ResetFrames(f0, f1)
        if f1 > #CF then f1 = #CF end
        for fi = f0, f1 do
            local fr = CF[fi]
            for pool in pairs(fr.used) do fr.used[pool] = 0 end
            fr.lineUsed = 0
        end
    end

    local SORT, nSort = {}, 0
    local function ItemCmp(a, b)
        local ka, kb = IK[a], IK[b]
        if ka ~= kb then return ka > kb end
        return a < b
    end

    local anyShown = false
    -- The leaves' screen bins (spec 5.13.4: a 16 x 12 grid), once per redraw: those overlapping some slot's box.
    local function BinLeaves(ux0, uy0, ux1, uy1)
        leafStamp = stats.redraws
        local cw, chh = cW / GX, cH / GY
        for c = 0, GX * GY - 1 do GN[c] = 0 end
        nBig = 0
        for q = 0, nLeaves * 12 - 12, 12 do
            local x0, x1 = LR[q + 9], LR[q + 11]
            if x1 >= ux0 and x0 <= ux1 then
                local y0, y1 = LR[q + 10], LR[q + 12]
                if y1 >= uy0 and y0 <= uy1 then
                    local gx0, gx1, gy0, gy1 = x0 / cw, x1 / cw, y0 / chh, y1 / chh
                    gx0, gx1, gy0, gy1 = gx0 - gx0 % 1, gx1 - gx1 % 1, gy0 - gy0 % 1, gy1 - gy1 % 1   -- (floor)
                    if gx0 < 0 then gx0 = 0 end
                    if gy0 < 0 then gy0 = 0 end
                    if gx1 >= GX then gx1 = GX - 1 end
                    if gy1 >= GY then gy1 = GY - 1 end
                    local i = q / 12 + 1
                    if (gx1 - gx0 + 1) * (gy1 - gy0 + 1) > 4 then        -- (a big one: in the list every slot reads)
                        nBig = nBig + 1
                        BIG[nBig] = i
                    else
                        for gy = gy0, gy1 do
                            for gx = gx0, gx1 do
                                local c = gy * GX + gx
                                local nn = GN[c] + 1
                                GN[c] = nn
                                GRID[c][nn] = i
                            end
                        end
                    end
                end
            end
        end
    end

    -- Slot j's leaves (its occluder X's box): from the cells under the box, each leaf once. Also the others whose
    -- restricting region overlaps the box (OVL).
    local function Gather(j, X)
        seenStamp = seenStamp + 1
        local cw, chh = cW / GX, cH / GY
        local bx0, by0, bx1, by1 = OX0[X], OY0[X], OX1[X], OY1[X]
        local gx0, gx1, gy0, gy1 = floor(bx0 / cw), floor(bx1 / cw), floor(by0 / chh), floor(by1 / chh)
        if gx0 < 0 then gx0 = 0 end
        if gy0 < 0 then gy0 = 0 end
        if gx1 >= GX then gx1 = GX - 1 end
        if gy1 >= GY then gy1 = GY - 1 end
        local L, nc = CAND[j], 0
        for gy = gy0, gy1 do
            for gx = gx0, gx1 do
                local c = gy * GX + gx
                local cell = GRID[c]
                for k = 1, GN[c] do
                    local i = cell[k]
                    if SEEN[i] ~= seenStamp then
                        SEEN[i] = seenStamp
                        local q = i * 12 - 12
                        if LR[q + 11] >= bx0 and LR[q + 9] <= bx1 and LR[q + 12] >= by0 and LR[q + 10] <= by1 then
                            nc = nc + 1
                            L[nc] = i
                        end
                    end
                end
            end
        end
        for k = 1, nBig do
            local i = BIG[k]
            local q = i * 12 - 12
            if LR[q + 11] >= bx0 and LR[q + 9] <= bx1 and LR[q + 12] >= by0 and LR[q + 10] <= by1 then
                nc = nc + 1
                L[nc] = i
            end
        end
        NC[j] = nc
        nOvl = 0
        for N = 1, nOcc do
            if N ~= X and OON[N] and RX1[N] > bx0 and RX0[N] < bx1 and RY1[N] > by0 and RY0[N] < by1 then
                nOvl = nOvl + 1
                OVL[nOvl] = N
            end
        end
    end

    -- Slot j's items (nItems of them) into its two copy frames: nearest key first, the nearest KEYS_MAX keys and copy
    -- textures up to COPY_TEX_MAX in all (what goes is the far end: the rest is still the near end of every ray); the
    -- kept keys in ascending order (back to front) get places 0, 1, ... -> copy textures used in all, and how many
    -- items X kept.
    local function EmitSlot(j, texTotal, hx, hy)
        local cnt = nItems
        if cnt == 0 or texTotal >= COPY_TEX_MAX then return texTotal, 0 end
        for i = 1, cnt do SORT[i] = i end
        for i = cnt + 1, nSort do SORT[i] = nil end
        nSort = cnt
        if cnt > 1 then table.sort(SORT, ItemCmp) end
        local keep, distinct, lastKey = 0, 0, nil
        for i = 1, cnt do
            local it = SORT[i]
            if IK[it] ~= lastKey then
                if distinct == KEYS_MAX then break end
                distinct, lastKey = distinct + 1, IK[it]
            end
            if ITY[it] == 1 then
                if texTotal >= COPY_TEX_MAX then break end
                texTotal = texTotal + 1
            end
            keep = i
        end
        distinct, lastKey = 0, nil
        for i = 1, keep do
            local kk = IK[SORT[i]]
            if kk ~= lastKey then distinct, lastKey = distinct + 1, kk end
        end
        local q = distinct
        lastKey = nil
        for i = 1, keep do
            local it = SORT[i]
            local kk = IK[it]
            if kk ~= lastKey then q, lastKey = q - 1, kk end
            local fr = CopyFrame(j * 2 + 1 + floor(q / 64))
            if ITY[it] == 1 then PutTex(fr, q % 64, it, hx, hy) else PutLine(fr, q % 64, it) end
        end
        stats.copyItems, stats.copyDropped = (stats.copyItems or 0) + cnt, (stats.copyDropped or 0) + (cnt - keep)
        return texTotal, keep
    end

    -- What each slot's last pass left: its occluder's id (false: none), the box of what it copied before the others
    -- restricted it (SLOTIB, 4 numbers; empty when nothing), the copy textures it uses and how many items it kept;
    -- whether this pass copies it again.
    local SLOTID, SLOTIB, SLOTTEX, SLOTKEEP, SLOTDIRTY = {}, {}, {}, {}, {}
    local function Overlap(a0, b0, a1, b1, c0, d0, c1, d1)
        return a1 + 1 >= c0 and a0 - 1 <= c1 and b1 + 1 >= d0 and b0 - 1 <= d1
    end
    -- Does slot j (occluder X, nil: none) need copying again? With all (the room redrew, a mark line changed, the
    -- occluders are others) every slot does; else when it holds another occluder than its copies were made for, its
    -- occluder changed, or one that changed restricts - or restricted - where it copies: what a slot copies before
    -- the restriction depends only on the room, the lines and its own occluder, and another occluder changes it only
    -- inside that one's restricting region, then or now.
    local function SlotDirty(j, X, all)
        if all or SLOTID[j] ~= (X and OIN[X].id or false) then return true end
        if not X then return false end
        local b = j * 4
        local x0, y0, x1, y1 = SLOTIB[b + 1], SLOTIB[b + 2], SLOTIB[b + 3], SLOTIB[b + 4]
        for c = 1, nChg do
            local N = CHG[c]
            if N == X then return true end
            local q = c * 4 - 4
            if Overlap(RX0[N], RY0[N], RX1[N], RY1[N], x0, y0, x1, y1)
                or Overlap(CB[q + 1], CB[q + 2], CB[q + 3], CB[q + 4], x0, y0, x1, y1) then
                return true
            end
        end
        return false
    end

    local function Pass(all)
        LoadCam()
        AssignSlots()
        local top, ux0, uy0, ux1, uy1 = -1, huge, huge, -huge, -huge
        for j = 0, OCC_SLOTS - 1 do
            local X = SLOTOCC[j]
            if X then
                top = j
                if OX0[X] < ux0 then ux0 = OX0[X] end
                if OY0[X] < uy0 then uy0 = OY0[X] end
                if OX1[X] > ux1 then ux1 = OX1[X] end
                if OY1[X] > uy1 then uy1 = OY1[X] end
            end
        end
        -- (the bins hold what any slot's box could want: built again when a redraw or the slots' boxes changed)
        if top >= 0 and (leafStamp ~= stats.redraws or ux0 < binX0 or uy0 < binY0 or ux1 > binX1 or uy1 > binY1) then
            if leafStamp == stats.redraws then ux0, uy0, ux1, uy1 = 0, 0, cW, cH end   -- (outgrown in a still room)
            binX0, binY0, binX1, binY1 = ux0, uy0, ux1, uy1
            BinLeaves(ux0, uy0, ux1, uy1)
        end
        -- the slots kept as they are count against the copy textures' cap first
        local texTotal, actors, hx, hy = 0, 0, cW / 2, cH / 2     -- (the scene's centre: the textures hang there)
        for j = 0, OCC_SLOTS - 1 do
            local X = SLOTOCC[j]
            local d = SlotDirty(j, X, all)
            SLOTDIRTY[j] = d
            if not d then
                texTotal = texTotal + SLOTTEX[j]
                if X then
                    OCNT[X] = SLOTKEEP[j]
                    if SLOTKEEP[j] > 0 then actors = actors + 1 end
                end
            end
        end
        local shown = texTotal
        stats.copyItems, stats.copyDropped = 0, 0
        for j = 0, OCC_SLOTS - 1 do
            if SLOTDIRTY[j] then
                local X, keep, before = SLOTOCC[j], 0, texTotal
                ResetFrames(j * 2 + 1, j * 2 + 2)
                if X then
                    Gather(j, X)
                    nItems = 0
                    ibx0, iby0, ibx1, iby1 = huge, huge, -huge, -huge
                    CopyLeaves(X, CAND[j], NC[j])
                    CopyLines(X)
                    texTotal, keep = EmitSlot(j, texTotal, hx, hy)
                    OCNT[X] = keep
                    if keep > 0 then actors = actors + 1 end
                    local b = j * 4
                    SLOTIB[b + 1], SLOTIB[b + 2], SLOTIB[b + 3], SLOTIB[b + 4] = ibx0, iby0, ibx1, iby1
                end
                SLOTID[j], SLOTTEX[j], SLOTKEEP[j] = X and OIN[X].id or false, texTotal - before, keep
                shown = shown + HideUnused(j * 2 + 1, j * 2 + 2)
            end
        end
        stats.copies, stats.copyActors, anyShown = shown, actors, shown > 0
    end

    -- Draw the copies for this frame: only when the room redrew, an occluder moved or a mark line changed (else
    -- they stand as they are). Also stops the time controller's clock.
    function Room.DrawCopies()
        local o = Room.opts
        if o.copies == false or not (meshOk and haveBasis) then
            if anyShown then Room.HideCopies() end
        elseif stats.redraw or occChanged or linesChanged then
            local all = stats.redraw or linesChanged or occAll
            occChanged, linesChanged, occAll = false, false, false
            Pass(all)
        end
        StopClock()
    end

    function Room.HideCopies()
        ResetFrames(1, #CF)
        HideUnused()
        anyShown, stats.copies, stats.copyActors = false, 0, 0
        wipe(SLOTID)
        occChanged, occAll = true, true
    end

    function Room.CopyFrames()
        local t = {}
        for fi = 1, #CF do t[fi] = CF[fi] end
        return t
    end

    -- the occluders as the copies saw them (UI._Occluders)
    function Room.Occluders()
        local out = {}
        for i = 1, nOcc do
            local o = OIN[i]
            out[i] = { id = o.id, family = FAMNAME[OFAM[i]], x = o.x, y = o.y, z = o.z, h = o.h, w = o.w, rb = o.rb,
                       box = { OX0[i], OY0[i], OX1[i], OY1[i] }, onScreen = OON[i] or false, slot = OSLOT[i] or -1,
                       copies = OCNT[i] or 0 }
        end
        return out
    end
end
InstallCopies()
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
    MKR.n = 0
    wipe(splitPrev)
    wipe(splitCur)
    dirty, forceOrder = true, true
    camKey[1] = nil
    if Room.HideCopies then Room.HideCopies() end
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
        if ns.Print then ns:Print("%s: this room has too many parts for the 3D renderer", Room.label) end
    end
    return meshOk
end

-- Merge render options (Room.opts) and draw again.
function Room.SetOpts(t)
    if type(t) ~= "table" then return end
    local opts = Room.opts
    local was, quads = opts.opaque ~= false, opts.quads ~= false
    for k, v in pairs(t) do opts[k] = v end
    if (opts.quads ~= false) ~= quads and curMesh then
        Room.Clear()                                     -- the prims change: prepare the room again
        meshOk = Prepare(curMesh) or false
    elseif (opts.opaque ~= false) ~= was and meshOk then
        Room.Clear()                                     -- the pools change: every piece comes back from its new one
        ComputePools()
    end
    dirty = true
end

-- A room point (arena coordinates) on the screen with the camera BeginFrame measured last: x, y in UI units from the
-- scene's bottom-left corner, and the depth; nil when it lies behind the camera or nothing was measured yet.
function Room.Project(x, y, z)
    if not haveBasis then return nil end
    local dx, dy, dz = x - ex, y - ey, z - ez
    local d = dx * Fx + dy * Fy + dz * Fz
    if d <= 1e-6 then return nil end
    local r, u = dx * Rx + dy * Ry, dx * Ux + dy * Uy + dz * Uz
    return cx + (r * exx + u * eyx) / d, cy + (r * exy + u * eyy) / d, d
end

-- The ray from the eye through a screen point (UI units from the scene's bottom-left corner), in arena coordinates:
-- eye x, y, z and the direction (one unit of depth per unit of length along the view: dx, dy, dz); nil before the
-- camera was measured.
function Room.ScreenRay(sx, sy)
    if not haveBasis then return nil end
    local det = exx * eyy - eyx * exy
    if det == 0 then return nil end
    local qx, qy = sx - cx, sy - cy
    local a = (qx * eyy - eyx * qy) / det                   -- right per unit of depth
    local b = (exx * qy - qx * exy) / det                   -- up per unit of depth
    return ex, ey, ez, Fx + a * Rx + b * Ux, Fy + a * Ry + b * Uy, Fz + b * Uz
end

---------------------------------------------------------------------------
-- Reports (the test hooks in UI.lua, spec section 8)
---------------------------------------------------------------------------

-- tau: the bound the picture on screen was drawn with; tauNext: what the next redraw uses; capped: pieces drawn
-- whole past the hard cap although over the bound; redone: how often the last redraw was collected again coarser;
-- textures: room textures made so far (all frames, all rooms); lent: textures that moved to another frame.
function Room.Stats()
    return { tau = CTL.used, tauNext = CTL.tau, target = tonumber(Room.opts.target) or CTL.target, hardCap = hardCap,
             leaves = nLeaves, clipped = nClipped, capped = nCapped, redone = stats.redone, copies = stats.copies or 0,
             copyActors = stats.copyActors or 0, copyItems = stats.copyItems or 0,
             copyDropped = stats.copyDropped or 0, lines = Room.ShownLines(), frames = nFrames, nodes = nNodes,
             prims = nPrims, redraw = stats.redraw, redraws = stats.redraws, pass1b = stats.pass1b, ms = stats.ms or 0,
             selfCheckPx = stats.selfCheckPx, midpoints = nPts - nV, collided = false, dilate = 0,
             textures = stats.textures, lent = stats.lent }
end

function Room.ShownTextures() return nLive end

function Room.ShownLines()
    local n = 0
    for f = 1, nFrames do
        local ls = roomFrames[f] and roomFrames[f].lines or {}     -- (a room that could not be prepared has none)
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

return Room
end
