if DisasterZoneBoot and DisasterZoneBoot.Run("Data/Tours/Strategy.lua", ...) then return end -- DisasterZone: Data/Tours/Strategy.lua
-- The tutorial of the strategy board (the engine: UI/Tour.lua). It runs on a practice board (Board:OpenSandbox):
-- High King Maulgar's starter, which is never kept as a draft, never saved and never shared.
-- A step that the member does themselves compares the board with what it was when the step started (enter / done);
-- nothing here changes how the board works. Everything is looked up when a step runs, so this file only needs
-- UI/Tour.lua loaded before it.
local addonName, ns = ...

local tconcat = table.concat

local BOSS = "GruulsLair:Maulgar"
local BW, BH = 1000, 666        -- the map's own units (UI/StrategyMap.lua)

local function B() return ns.StrategyBoard end
local function W() return B():GetWindow() end
local function st() return B():GetState() end
local function pg()
    local s = st()
    return s.strat and s.strat.p[s.page] or nil
end
local function canvas() return W().canvas end
local function glyph(i) return ns.UI:AtlasIconText(i, 12, i == 14 and ns.Style.C.GOLD or nil) end
local function tools() return W().tools end
local function blocks() return W().blocks end

-- The values of some fields of every drawing on the page, as one text: a change shows as another text.
local function drawingSig(...)
    local out = {}
    for _, e in ipairs(pg().e) do
        for i = 1, select("#", ...) do out[#out + 1] = tostring(e[(select(i, ...))]) end
    end
    return tconcat(out, ",")
end

-- Who fits the player slots of the page (the columns' rules and the slots' own).
local function filterSig()
    local out = {}
    for _, k in ipairs(pg().k) do
        for ci, c in ipairs(k.c) do
            out[#out + 1] = tostring(c.f)
            for row = 1, k.r do
                local v = k.d and k.d[row] and k.d[row][ci]
                out[#out + 1] = type(v) == "table" and tostring(v.f) or "-"
            end
        end
    end
    return tconcat(out, ",")
end

-- The first cell on the screen that pred likes.
local function findCell(pred)
    for _, b in ipairs(blocks().blocks) do
        if b:IsShown() then
            for _, c in ipairs(b.cells) do
                if c:IsShown() and pred(c) then return c end
            end
        end
    end
    return nil
end
local function slotCell() return findCell(function(c) return c.slotRef ~= nil end) end
local function targetCell() return findCell(function(c) return c.targetInfo ~= nil end) end

-- A drawing's place on the map, as the tour's cursor takes it.
local function onMap(e)
    return { canvas().frame, e.x / BW, e.y / BH }
end

-- A drawing that isn't linked to a job yet (zones first), or nil.
local function unlinked()
    local any
    for _, e in ipairs(pg().e) do
        if e.t ~= "s" and not e.ln then
            if e.t == "z" then return e end
            any = any or e
        end
    end
    return any
end

local function firstPage()
    local s = st()
    if s.page ~= 1 then
        s.page = 1
        B():Refresh()
    end
end

local function selectTool()
    canvas():SetTool("select")
    B():RefreshTools()
end

-- The card of Add a block (under the tables while editing) with that title, or nil.
local function addCard(label)
    for _, c in ipairs(blocks().cards or {}) do
        if c:IsShown() and c.title and c.title:GetText() == label then return c end
    end
    return nil
end

-- A block from Add a block's template of that label, as its card adds it.
local function addTemplate(label)
    local p = pg()
    if #p.k >= ns.Strategy.MAX_BLOCKS then return end
    for _, t in ipairs(ns.StrategyBlocksUI.TEMPLATES) do
        if t.label == label then
            local k = t.make()
            k.id = ns.Strategy:NewPartId(st().strat, "k")
            p.k[#p.k + 1] = k
            blocks():Changed()
            return
        end
    end
end

-- The steps after "Blocks" point into a block: when the member skipped making one, the first suggested block.
local function oneBlock()
    local p = pg()
    if #p.k > 0 then return end
    local sg = blocks():Suggestions(p)[1]
    if sg then sg.apply() else addTemplate("Players with targets") end
end

-- The page in the boss' room (UI/StrategyMap3D.lua) or on the map. The 2D chapters point at the map and watch its
-- zoom, so they put the board back on the map; the 3D steps go into the room at once, however the member came.
local function v3() return canvas().v3 end
local function in3D() return canvas():Is3D() end
local function view3D(on)
    if in3D() ~= on then canvas():Set3D(on, false) end
end
local function flat() view3D(false) end
-- No room to show this page in (the 3D files come with an update and need a client restart).
local function no3D() return (canvas():Room3D()) == nil end
-- Where the camera is going (where it is when it isn't moving).
local function cam()
    local v = v3()
    return v.anim and v.anim.to or v.orb
end
-- A drawing's spot in the room on the screen, as the tour's cursor takes it, or nil when it is out of sight.
local function inRoom(e)
    local v, f = v3(), canvas().frame
    if not (e and v and in3D()) then return nil end
    local g = v:Geo(e)
    local sx, sy = v:Proj(g.x, g.y, g.z)
    local w, h = f:GetWidth() or 0, f:GetHeight() or 0
    if not sx or w <= 0 or h <= 0 or sx < 0 or sx > w or sy < 0 or sy > h then return nil end
    return { f, sx / w, 1 - sy / h }
end

local basics = {
    {
        title = "Welcome to the strategy board",
        text = "A strategy is a map you draw on, plus tables of jobs beside it.\n\nThis is a practice board for High King "
            .. "Maulgar. Nothing you do here is saved or shared, so try everything.",
    },
    {
        title = "The map",
        anchor = function() return canvas().frame end,
        text = "The boss room, with the boss and his adds where they stand at the pull. Zones, arrows, icons and texts "
            .. "go on top of it.\n\nThe switch under it shows the same page in the room itself, in 3D: that has a "
            .. "chapter of its own.",
    },
    {
        title = "The jobs",
        anchor = function() return blocks().scroll end,
        side = "left",
        text = "Tables of jobs: who tanks what, who interrupts, who stands where. The strategy holds the job slots; "
            .. "the raid leader puts the names in for each raid.",
    },
    {
        title = "Zooming",
        anchor = function() return canvas().frame end,
        text = "The map zooms around its middle.",
        hint = "Scroll the mouse wheel over the map.",
        enter = function(ctx) ctx.z = pg().vz end,
        done = function(ctx) return pg().vz ~= ctx.z end,
        ghost = function() return { from = { canvas().frame, 0.5, 0.5 }, label = "Mouse wheel" } end,
    },
    {
        title = "Moving the map",
        anchor = function() return tools().btns[2] end,
        side = "top",
        text = "The hand tool moves the map under your drawings.",
        hint = "Pick the hand tool.",
        done = function() return canvas().tool == "pan" end,
        ghost = function() return { from = { tools().btns[2], 0.5, 0.5 } } end,
    },
    {
        title = "Moving the map",
        anchor = function() return canvas().frame end,
        text = "Frame the room the way the raid should see it. Do this first, then draw: drawings stay where they are "
            .. "when the map moves.",
        hint = "Drag the map.",
        enter = function(ctx) ctx.x, ctx.y = pg().vx, pg().vy end,
        done = function(ctx) return pg().vx ~= ctx.x or pg().vy ~= ctx.y end,
        ghost = function()
            return { from = { canvas().frame, 0.6, 0.45 }, to = { canvas().frame, 0.42, 0.6 }, label = "Drag" }
        end,
    },
    {
        title = "Another floor",
        anchor = function() return W().mapBtn end,
        side = "left",
        text = "Each page has its own map. This link lists the floors of the raid, each with who is fought there; a "
            .. "right-click on the map has the same list.",
    },
    {
        title = "Pages",
        anchor = function() return W().tabs[1], W().addPage end,
        side = "bottom",
        text = function()
            return "A fight with phases gets a page per phase, each with its own map and jobs. The " .. glyph(14)
                .. " on the open tab renames, moves or deletes it."
        end,
        hint = "Click + to add a page.",
        enter = function(ctx) ctx.n = #st().strat.p end,
        done = function(ctx) return #st().strat.p > ctx.n end,
        ghost = function() return { from = { W().addPage, 0.5, 0.5 } } end,
    },
    {
        title = "Pages",
        anchor = function() return W().tabs[1] end,
        side = "bottom",
        text = "The new page starts with the same map and nothing on it.",
        hint = "Click the first tab to go back.",
        skip = function() return #st().strat.p < 2 end,        -- (no page was added)
        done = function() return st().page == 1 end,
        ghost = function() return { from = { W().tabs[1], 0.5, 0.5 } } end,
    },
}

local drawing = {
    {
        title = "Zones",
        anchor = function() return tools().btns[3] end,
        side = "top",
        text = "Zones mark where to stand and what to stay out of.",
        hint = "Pick the circle tool.",
        done = function() return canvas().tool == "circle" end,
        ghost = function() return { from = { tools().btns[3], 0.5, 0.5 } } end,
    },
    {
        title = "Zones",
        anchor = function() return canvas().frame end,
        text = "A circle grows from its centre. A plain click makes one of the usual size.",
        hint = "Drag on the map to draw a zone.",
        enter = function(ctx) ctx.n = #pg().e end,
        done = function(ctx) return #pg().e > ctx.n and canvas().drag == nil end,
        ghost = function()
            return { from = { canvas().frame, 0.3, 0.72 }, to = { canvas().frame, 0.38, 0.84 }, label = "Drag" }
        end,
    },
    {
        title = "Colours",
        anchor = function() return tools().swatches[1], tools().swatches[#tools().swatches] end,
        side = "top",
        text = "The zone you drew is selected: the gold box. A colour goes on the selection and on what you draw next.",
        hint = "Pick another colour.",
        enter = function(ctx) ctx.c = canvas().color end,
        done = function(ctx) return canvas().color ~= ctx.c end,
    },
    {
        title = "Move and resize",
        anchor = function() return canvas().frame end,
        text = "Drag a drawing to move it. Drag a gold handle to resize it. Hold Alt while dragging to snap.",
        hint = "Move or resize something.",
        enter = function(ctx) ctx.sig = drawingSig("x", "y", "w", "h", "x2", "y2") end,
        done = function(ctx)
            return canvas().drag == nil and drawingSig("x", "y", "w", "h", "x2", "y2") ~= ctx.sig
        end,
        ghost = function()
            local e = canvas():GetSelected() or pg().e[#pg().e]
            if not e then return nil end
            return { from = onMap(e), to = { canvas().frame, e.x / BW + 0.1, e.y / BH - 0.08 }, label = "Drag" }
        end,
    },
    {
        title = "Labels",
        anchor = function() return canvas().frame end,
        text = "A zone or an icon can say what it is: \"Melee\", \"Stack here\".",
        hint = "Double-click a zone or an icon and type a label.",
        enter = function(ctx) ctx.sig = drawingSig("l") end,
        done = function(ctx) return drawingSig("l") ~= ctx.sig end,
        ghost = function()
            local e = canvas():GetSelected() or pg().e[#pg().e]
            return e and { from = onMap(e), label = "Double-click" } or nil
        end,
    },
    {
        title = "Icons, texts, arrows",
        anchor = function() return canvas().frame end,
        text = "A right-click on an empty spot adds something there: Icon has the raid marks, class and spell icons "
            .. "and this boss' creatures. The arrow, line, icon and text tools in the toolbar do the same by hand.",
        hint = "Add one more drawing of any kind.",
        enter = function(ctx) ctx.n = #pg().e end,
        done = function(ctx) return #pg().e > ctx.n and canvas().drag == nil end,
        ghost = function() return { from = { canvas().frame, 0.7, 0.75 }, label = "Right-click" } end,
    },
    {
        title = "Several at once",
        anchor = function() return canvas().frame end,
        text = "Drag a box over an empty part of the map to select what it touches, or Shift-click drawings one by "
            .. "one. A selection moves, copies (Ctrl+C, Ctrl+V) and deletes together; Ctrl+G makes it a group "
            .. "that stays together.",
        hint = "Select two or more drawings.",
        done = function() return canvas().drag == nil and canvas():SelectionCount() > 1 end,
        ghost = function()
            return { from = { canvas().frame, 0.25, 0.15 }, to = { canvas().frame, 0.7, 0.4 }, label = "Drag a box" }
        end,
    },
    {
        title = "Undo",
        -- (undo shows once there is something to undo: before that, where it comes, after the colours)
        anchor = function()
            if not tools().undoBtn:IsShown() then return tools().swatches[#tools().swatches] end
            return tools().undoBtn, tools().redoBtn
        end,
        side = "top",
        text = "Every change can be taken back, and brought back again: this button (redo comes beside it once "
            .. "there is something to bring back), or Ctrl+Z and Ctrl+Y.",
        hint = "Undo your last change.",
        enter = function(ctx) ctx.i = st().histI or 0 end,
        done = function(ctx) return (st().histI or 0) < ctx.i end,
    },
    {
        title = "Keys and mouse",
        anchor = function() return W().helpBtn end,
        side = "bottom",
        text = "? > Keyboard and mouse lists every shortcut: copy and paste, duplicate, group, nudge with the arrows, "
            .. "and the camera in 3D. The tutorial's chapters are in that menu too.\n\nNext: the same page in the "
            .. "boss' room.",
    },
}

---------------------------------------------------------------------------
-- The room in 3D
---------------------------------------------------------------------------

local abs = math.abs

-- The page was put on another floor (the basics' map menu): back on the room's own, so the room can open.
local function roomMap()
    local _, why, room = canvas():Room3D()
    if why ~= "map" or not room then return end
    for _, m in ipairs(ns.Data and ns.Data.RaidMaps or {}) do
        if m.file == room.map then
            local p = pg()
            p.m, p.vx, p.vy, p.vz = m.id, 500, 500, 100
            B():MarkDirty(true)
            return
        end
    end
end

-- What to right-click for View from here: the selected drawing, else the last zone, else the boss.
local function viewTarget()
    local e = canvas():GetSelected()
    if e then return e end
    local list = pg().e
    for i = #list, 1, -1 do
        if list[i].t == "z" then return list[i] end
    end
    local _, model = v3():FirstModel()
    return model
end

-- Walking needs the room's ground (the walk button is there only then).
local function noWalk()
    local room = canvas():Room3D()
    return not (room and ns.Render3D.Ground and ns.Render3D.Ground(room))
end

local room3d = {
    {
        title = "No 3D here yet",
        skip = function() return not no3D() end,
        -- (the rooms are the DisasterZone_Rooms addon: missing or turned off, it says which; else a restart)
        text = function()
            local r3 = ns.Render3D
            local problem = r3 and r3.DataProblem and r3.DataProblem()
            if problem then
                return "The board can show a page in the boss' room in 3D, as the game draws it. " .. problem
                    .. "\n\nNext: the tables of jobs."
            end
            return "The board can show a page in the boss' room in 3D, as the game draws it. Those files come with "
                .. "an update, and the game only reads new files when it starts: restart the client once (a /reload "
                .. "is not enough), then come back to this chapter.\n\nNext: the tables of jobs."
        end,
    },
    {
        title = "Into the room",
        anchor = function() return W().mode2d, W().mode3d end,
        skip = no3D,
        text = "Every raid boss has its room in 3D, as the game draws it, with the boss and its adds as their own "
            .. "models at their true size. It is the same page: what is on the map stands in the room, and what you draw in the room is "
            .. "on the map.",
        hint = "Click 3D under the map's right corner.",
        done = in3D,
        ghost = function() return { from = { W().mode3d, 0.5, 0.5 } } end,
    },
    {
        title = "Turning the view",
        anchor = function() return canvas().frame end,
        skip = no3D,
        text = "The camera circles a point on the floor. Right-drag turns and tilts it; Q and E turn it 45 degrees.",
        hint = "Right-drag in the room.",
        enter = function(ctx)
            view3D(true)
            local o = cam()
            ctx.h, ctx.p = o.heading, o.pitch
        end,
        done = function(ctx)
            local o = in3D() and cam()
            return o and (abs(o.heading - ctx.h) > 0.05 or abs(o.pitch - ctx.p) > 0.05) or false
        end,
        ghost = function()
            return { from = { canvas().frame, 0.62, 0.5 }, to = { canvas().frame, 0.42, 0.4 }, label = "Right-drag" }
        end,
    },
    {
        title = "Closer and farther",
        anchor = function() return canvas().frame end,
        skip = no3D,
        text = "The wheel zooms. Middle-drag moves the view (a left-drag with the hand tool does too), and a "
            .. "double-click on the floor looks there.",
        hint = "Zoom in with the mouse wheel.",
        enter = function(ctx)
            view3D(true)
            ctx.d = cam().dist
        end,
        done = function(ctx) return in3D() and abs(cam().dist - ctx.d) > 0.05 * ctx.d end,
        ghost = function() return { from = { canvas().frame, 0.5, 0.5 }, label = "Mouse wheel" } end,
    },
    {
        title = "The camera buttons",
        anchor = function() return unpack(v3().hudBtns) end,
        skip = no3D,
        enter = function() view3D(true) end,
        text = "From the left: turn left and right; From above (straight down, north up, like the map; again tilts "
            .. "back); the whole room (Home); the small map; Walk. With a job on the plan an eye comes in too: My "
            .. "spot.",
    },
    {
        title = "The small map",
        anchor = function() return v3().inset.frame end,
        skip = no3D,
        text = "The map in the corner shows where the camera is (the gold arrow) and what it sees (the white "
            .. "outline). A click on it looks there; the map button hides it.",
        hint = "Click a spot on the small map.",
        enter = function(ctx)
            view3D(true)
            if not v3().insetOn then v3():ToggleInset() end
            local o = cam()
            ctx.x, ctx.y = o.x, o.y
        end,
        done = function(ctx)
            local o = in3D() and cam()
            return o and abs(o.x - ctx.x) + abs(o.y - ctx.y) > 1 or false
        end,
        ghost = function() return { from = { v3().inset.frame, 0.25, 0.7 } } end,
    },
    {
        title = "Drawing in the room",
        anchor = function() return canvas().frame, tools().btns[3] end,
        skip = no3D,
        text = "Every tool works here. A zone lies on the floor, down steps and up onto platforms; an arrow runs "
            .. "along the floor; icons and texts stand over their spot like name plates.",
        hint = "Pick the circle tool and drag on the floor.",
        enter = function(ctx)
            view3D(true)
            ctx.n = #pg().e
        end,
        done = function(ctx) return in3D() and #pg().e > ctx.n and canvas().drag == nil end,
        ghost = function()
            local tool = canvas().tool
            if tool == "select" or tool == "pan" then return { from = { tools().btns[3], 0.5, 0.5 } } end
            return { from = { canvas().frame, 0.4, 0.62 }, to = { canvas().frame, 0.47, 0.72 }, label = "Drag" }
        end,
    },
    {
        title = "View from here",
        anchor = function() return canvas().frame end,
        skip = no3D,
        text = "Right-click a drawing > View from here: you stand on it at eye height, looking at the boss (on an "
            .. "arrow: from its start, along it). That is what the player sent there sees. The wheel steps back out.",
        hint = "Right-click a drawing and pick View from here.",
        enter = function() view3D(true) end,
        done = function() return in3D() and cam().dist < 3 end,
        stay = true,                                            -- (look round from there)
        ghost = function()
            local at = inRoom(viewTarget())
            return at and { from = at, label = "Right-click" } or nil
        end,
    },
    {
        title = "Walking in the room",
        -- (once walking, the room is lit: nobody walks in the dark)
        anchor = function() return v3():IsWalking() and canvas().frame or v3().walkBtn end,
        skip = function() return no3D() or noWalk() end,
        text = "Walk round the room as your own character: drag this button to where you want to start, or click "
            .. "it. WASD or the arrows move you, Space jumps, the mouse turns the camera, Esc stops. The tools work "
            .. "on while you walk, and on a real strategy the others who have it open see you there.",
        hint = "Click the button, take a few steps, then press Esc.",
        enter = function() view3D(true) end,
        done = function(ctx)
            if not in3D() then return false end
            if v3():IsWalking() then ctx.walked = true end
            return ctx.walked == true and not v3():IsWalking()
        end,
        ghost = function() return not v3():IsWalking() and { from = { v3().walkBtn, 0.5, 0.5 } } or nil end,
    },
    {
        title = "Back to the map",
        anchor = function() return W().mode2d, W().mode3d end,
        skip = no3D,
        text = "2D lays the room back down as the map. Use whichever shows the fight better: both are the same "
            .. "page, and every raider can switch to 3D when they read the plan.\n\nNext: the tables of jobs.",
        hint = "Click 2D.",
        done = function() return not in3D() end,
        ghost = function() return { from = { W().mode2d, 0.5, 0.5 } } end,
    },
}

local jobs = {
    {
        title = "Blocks",
        anchor = function() return blocks().scroll end,
        side = "left",
        text = function()
            if #pg().k > 0 then
                return "A block is a small table of jobs. Add a block, under the tables, starts another one."
            end
            return "A block is a small table of jobs. Under Add a block, the first cards build one from the creatures "
                .. "on the map: a row each, already linked to them. The templates under them start empty."
        end,
        hint = "Click a card to add a block.",
        enter = function(ctx) ctx.n = #pg().k end,
        done = function(ctx) return #pg().k > ctx.n end,
    },
    {
        title = "Linked to the map",
        anchor = function() return canvas().frame end,
        enter = oneBlock,
        text = function()
            for _, e in ipairs(pg().e) do
                if e.ln then
                    return "The creature on the map now shows the job it is linked to. Once a raid is assigned, the "
                        .. "player's name stands there instead: everyone sees their spot on the map."
                end
            end
            return "A drawing can be linked to a job. Once a raid is assigned, the player's name stands on the "
                .. "drawing: everyone sees their spot on the map. A later step links one."
        end,
    },
    {
        title = "Who fits a slot",
        anchor = function() return slotCell() end,
        side = "left",
        text = "A player slot can be limited to a role or to classes. Suggest fill uses that when the raid leader "
            .. "assigns the raid.",
        hint = "Click the slot and pick a role or a class.",
        enter = function(ctx) ctx.sig = filterSig() end,
        done = function(ctx) return filterSig() ~= ctx.sig end,
        ghost = function()
            local c = slotCell()
            return c and { from = { c, 0.3, 0.5 } } or nil
        end,
    },
    {
        title = "Targets",
        anchor = function() return targetCell() end,
        side = "left",
        text = "A target cell says what the job is about. Click it to type a label or pick an icon, or drop an icon "
            .. "from the map on it. Its menu also ties the row to the boss' abilities: the in-fight helpers chapter "
            .. "shows how.",
    },
    {
        title = "Linking a drawing yourself",
        anchor = function() return canvas().frame, slotCell() end,
        side = "bottom",
        text = "Dropped on a slot, a drawing shows that player. On a column header or a block's title bar it shows "
            .. "everyone in the column or the block.",
        hint = "Hold Shift and drag a drawing onto a table.",
        enter = function(ctx)
            -- something to link: a zone, when everything on the map is linked already
            if not unlinked() then
                canvas():Place({ t = "z", s = "c", x = 300, y = 480, w = 110, h = 110, c = canvas().color, l = "Melee" })
            end
            ctx.sig = drawingSig("ln")
        end,
        done = function(ctx) return canvas().drag == nil and drawingSig("ln") ~= ctx.sig end,
        ghost = function()
            local e, c = unlinked(), slotCell()
            if not (e and c) then return nil end
            return { from = onMap(e), to = { c, 0.4, 0.5 }, label = "Shift + drag" }
        end,
    },
    {
        title = "Names on the map",
        anchor = function() return slotCell() end,
        side = "left",
        text = "It works the other way round too: drag a player slot onto the map to put a name marker there. It "
            .. "shows whoever gets that slot.",
        ghost = function()
            local c = slotCell()
            return c and { from = { c, 0.4, 0.5 }, to = { canvas().frame, 0.55, 0.7 }, label = "Drag" } or nil
        end,
    },
    {
        title = "Shaping a block",
        anchor = function() return blocks().blocks[1] end,
        side = "left",
        text = function()
            return "The title row (or its " .. glyph(24) .. " button) opens the block's menu: rename, colour, track it "
                .. "in the fight (an interrupt rotation, dispels), copy, move or delete it. + Row and + Column grow "
                .. "it; a click on a column title changes the column."
        end,
    },
    {
        title = "Other kinds of tables",
        anchor = function() return addCard("Players with targets") or blocks().addBtn end,
        side = "left",
        text = "Add a block has a template for the usual shapes: players with targets, a rotation (interrupts, "
            .. "misdirects), groups or zones, pairs (Innervate: from, to), a single job with a timing, dispels, plain "
            .. "text. Each is a starting point: columns and rows can be changed afterwards.",
    },
    {
        title = "Page notes",
        anchor = function() return blocks().notesBtn end,
        side = "left",
        text = "Free text under the tables, for what doesn't fit one. Click it and type: it is written in place.",
    },
    {
        title = "Saving",
        anchor = function() return W().cancelBtn end,
        side = "bottom",
        text = "On a real strategy, Save sits here and shares it with the guild; until then your work is a private "
            .. "draft, tagged Unsaved: it survives closing the window, a reload and a logout. This practice board has "
            .. "Close instead.\n\nNext: the helpers that follow a table during the fight.",
    },
}

---------------------------------------------------------------------------
-- In the fight
---------------------------------------------------------------------------

local function S() return ns.Strategy end

-- The first block (and its frame) that pred likes.
local function findBlock(pred)
    for i, k in ipairs(pg().k) do
        if pred(k) then return k, blocks().blocks[i] end
    end
    return nil
end
local function isRotation(k)
    for _, c in ipairs(k.c) do
        if c.t == "o" then return true end
    end
    return false
end
local function countBlocks(pred)
    local n = 0
    for _, k in ipairs(pg().k) do
        if pred(k) then n = n + 1 end
    end
    return n
end
local function trackSig()
    local out = {}
    for _, k in ipairs(pg().k) do out[#out + 1] = tostring(S().TrackKind(k)) end
    return tconcat(out, ",")
end

local helpers = {
    {
        title = "Tables the addon follows",
        text = "A plan doesn't have to stay on paper. A table can be tracked during the fight: whose interrupt it "
            .. "is, whether a misdirect went out, a dispel that is needed right now.\n\nThat is set per block.",
    },
    {
        title = "A rotation",
        anchor = function() return addCard("Rotation") or blocks().scroll end,
        side = "left",
        text = "An ordered table: the players take turns from the top.",
        hint = "Click Rotation under Add a block.",
        enter = function(ctx) ctx.n = countBlocks(isRotation) end,
        done = function(ctx) return countBlocks(isRotation) > ctx.n end,
    },
    {
        title = "Track in fight",
        anchor = function()
            local _, frame = findBlock(isRotation)
            return frame
        end,
        side = "left",
        text = "Tracking says what the table means. An interrupt rotation is followed through the combat log: "
            .. "everyone in it sees whose kick it is. Other kinds: misdirections, Bloodlust, Power Infusion, "
            .. "Innervate, curses, dispels.",
        hint = "Click the block's title row, then Track in fight > Interrupts.",
        enter = function(ctx)
            -- something to track: a rotation, when the step before was skipped
            if not findBlock(isRotation) then addTemplate("Rotation") end
            ctx.sig = trackSig()
        end,
        done = function(ctx) return trackSig() ~= ctx.sig end,
    },
    {
        title = "What a row is about",
        anchor = function()
            local k = findBlock(isRotation)
            return findCell(function(c) return c.targetInfo ~= nil and (k == nil or c.targetInfo.k == k) end)
        end,
        side = "left",
        text = "In a target cell's menu, Abilities lists the boss' casts: tick the ones this row is about. Only when "
            .. "limits a row to part of the fight: the boss below a health percentage, or while it has a buff.",
    },
    {
        title = "Raid marks",
        anchor = function() return W().moreBtn end,
        side = "bottom",
        text = function()
            return "Right-click a creature's portrait on the map > Raid mark to give it a skull or a cross. With "
                .. "Auto-mark on (in the " .. glyph(24) .. " menu here), the raid leader's DisasterZone puts those "
                .. "marks on the mobs as their nameplates appear."
        end,
    },
    {
        title = "Practice",
        anchor = function() return W().moreBtn end,
        side = "bottom",
        text = function()
            return "Practice, in the " .. glyph(24) .. " menu, plays a minute of this fight for you alone, with demo "
                .. "players in the other slots: a quick check that the tables you track go the way you meant, before a "
                .. "raid relies on them. Try it once the tutorial is over.\n\nNext: putting a raid's players into the "
                .. "slots."
        end,
    },
}

---------------------------------------------------------------------------
-- Assigning a raid
---------------------------------------------------------------------------

local function me() return ns.Util.PlayerKey() end
local function assign() return st().assign end
local function assignCount()
    local n = 0
    for _ in pairs(assign()) do n = n + 1 end
    return n
end
local function mine()
    for _, key in pairs(assign()) do
        if key == me() then return true end
    end
    return false
end
local function emptySlotCell()
    return findCell(function(c) return c.slotRef ~= nil and assign()[c.slotRef] == nil end)
end
local function chip(pred)
    for _, c in ipairs(W().pool.chips) do
        if c:IsShown() and (pred == nil or pred(c)) then return c end
    end
    return nil
end
local function myChip() return chip(function(c) return c.key == me() end) end

-- Limits the first table's players to tanks (something for Suggest fill to work with). clear: and empties them.
local function tankSlots(p, clear)
    local k = p.k[1]
    if not k then return end
    for ci, c in ipairs(k.c) do
        if c.t == "p" then
            c.f = "tank"
            if clear then
                for row = 1, k.r do assign()[S().SlotRef(k.id, row, ci)] = nil end
            end
            return
        end
    end
end

-- The practice board's jobs when a chapter starts without them: a block for every creature on the first page.
local function seed()
    local p = st().strat.p[1]
    if #p.k > 0 then return end
    for _ = 1, S().MAX_BLOCKS do
        local sg = blocks():Suggestions(p)[1]
        if not sg then break end
        sg.apply()
    end
    tankSlots(p)
end

-- Is there an empty slot limited to a role or a class (what Suggest fill fills)?
local function emptyFiltered()
    for _, sl in ipairs(S():GetSlots(st().strat)) do
        if sl.f and not assign()[sl.ref] then return true end
    end
    return false
end

-- My name on the first page's map, unless a marker shows it already: beside the drawing linked to my job (else the
-- first creature), towards the middle of the room. First on the page, so My spot (3D) goes there first.
local function myMarker()
    local s = st()
    local p = s.strat.p[1]
    if #p.e >= S().MAX_ELEMENTS then return end
    local mine, ref = {}, nil
    for _, sl in ipairs(S():GetSlots(s.strat)) do
        if s.assign[sl.ref] == me() then
            mine[sl.ref] = true
            ref = ref or sl.ref
        end
    end
    if not ref then return end
    local near
    for _, e in ipairs(p.e) do
        if e.t == "s" and mine[e.r] then return end
        if not near and e.ln and mine[e.ln] then near, ref = e, e.ln end
    end
    if not near then
        for _, e in ipairs(p.e) do
            if e.t == "i" then
                near = e
                break
            end
        end
    end
    local x, y = BW / 2, BH / 2
    if near then
        local dx, dy = x - near.x, y - near.y
        local d = math.sqrt(dx * dx + dy * dy)
        local k = d > 1 and math.min(60, d) / d or 0
        x, y = near.x + dx * k, near.y + dy * k
    end
    table.insert(p.e, 1, { t = "s", x = x, y = y, r = ref })
end

-- Names in every slot of the practice board: the players who fit first, then whoever has the fewest jobs; me in one.
local function fillNames()
    local s = st()
    local members = blocks().opts.members() or {}
    if #members == 0 then return end
    local a = S():SuggestFill(s.strat, s.assign, members)
    local n = 0
    for _, sl in ipairs(S():GetSlots(s.strat)) do
        if not a[sl.ref] then
            n = n + 1
            a[sl.ref] = members[(n - 1) % #members + 1].key
        end
    end
    local has = false
    for _, key in pairs(a) do has = has or key == me() end
    if not has then
        local slots = S():GetSlots(s.strat)
        if slots[#slots] then a[slots[#slots].ref] = me() end
    end
    s.assign = a
    myMarker()
    B():Refresh()
end

local assigning = {
    {
        title = "Assigning a raid",
        text = "A strategy holds the jobs; each raid gets its own names. The raid's leader (or the Guild Master) opens "
            .. "a boss from the planned raid (Raids > Upcoming > the raid > Assignments) and clicks Assign players."
            .. "\n\nThis practice board has a demo raid: you and nine made-up players.",
    },
    {
        title = "This raid's players",
        anchor = function() return W().pool end,
        side = "left",
        text = "Everyone signed up for the raid, and whoever is in your raid group, by role. A player who has a job "
            .. "fades; two jobs or more put the number on their circle. The map stays as it is.",
    },
    {
        title = "Putting a player in a slot",
        anchor = function() return W().pool, emptySlotCell() or slotCell() end,
        side = "left",
        text = "Three ways: drag a player onto a slot; click the player, then the slot; or click the slot and pick "
            .. "from its list, where the players who fit come first.",
        hint = "Put a player in a slot.",
        enter = function(ctx) ctx.n = assignCount() end,
        done = function(ctx) return assignCount() > ctx.n end,
        ghost = function()
            local c, cell = chip(), emptySlotCell()
            if not (c and cell) then return nil end
            return { from = { c, 0.3, 0.5 }, to = { cell, 0.4, 0.5 }, label = "Drag" }
        end,
    },
    {
        title = "Suggest fill",
        anchor = function() return W().pool.suggestBtn end,
        side = "top",
        text = "Fills the empty slots that are limited to a role or a class with players who fit, spreading the "
            .. "jobs. Slots open to anyone stay for you to decide.",
        hint = "Click Suggest fill.",
        enter = function(ctx)
            -- something for it to fill: the first table's slots are for tanks
            if not emptyFiltered() then
                tankSlots(pg(), true)
                B():Refresh()
            end
            ctx.n = assignCount()
        end,
        done = function(ctx) return assignCount() > ctx.n end,
        ghost = function() return { from = { W().pool.suggestBtn, 0.5, 0.5 } } end,
    },
    {
        title = "Checks while you assign",
        anchor = function() return blocks().scroll end,
        side = "left",
        text = "A player placed twice in the same table turns orange. A name in red is someone who isn't signed up "
            .. "for this raid. A right-click on a slot clears it; Ctrl+Z takes a step back.",
    },
    {
        title = "From the last raid",
        -- (Carry over shows once an earlier raid used the strategy, Clear all once there are names)
        anchor = function() return W().pool.carryBtn, W().pool.clearBtn, W().pool.suggestBtn end,
        side = "top",
        text = "On a raid's board, Carry over comes beside Suggest fill once an earlier raid used this strategy: it "
            .. "starts from that raid's names, so a farm boss takes a few fixes instead of a full round. Clear all "
            .. "empties every slot.",
    },
    {
        title = "A job for you",
        anchor = function() return W().pool, emptySlotCell() or slotCell() end,
        side = "left",
        text = "The next chapter shows the plan the way a raider sees it, so take a job yourself.",
        hint = "Put yourself in a slot.",
        skip = function() return mine() end,
        done = function() return mine() end,
        ghost = function()
            local c, cell = myChip(), emptySlotCell() or slotCell()
            if not (c and cell) then return nil end
            return { from = { c, 0.3, 0.5 }, to = { cell, 0.4, 0.5 }, label = "Drag" }
        end,
    },
    {
        title = "Saving the names",
        anchor = function() return W().cancelBtn end,
        side = "bottom",
        text = "On a real raid, Save sits here and shares the names with the raid; until then they are a draft of "
            .. "yours. There the strategy's name in the header is a switch too: it puts the raid on another strategy "
            .. "of the boss and keeps the names of the slots both have.\n\nNext: the plan as a raider reads it.",
    },
}

---------------------------------------------------------------------------
-- Reading a plan
---------------------------------------------------------------------------

local reading = {
    {
        title = "Reading a plan",
        text = "This is what every raider sees. Open a boss from a raid (Raids > Upcoming > the raid > Assignments), "
            .. "or click the header of the jobs panel that appears near the boss.",
    },
    {
        title = "Your jobs",
        anchor = function() return W().jobs end,
        side = "top",
        text = "Everything you are assigned to on this board, across all its pages. A click goes to the page and "
            .. "lights the row and its drawing.",
    },
    {
        title = "Where you stand",
        anchor = function() return canvas().frame end,
        text = "Linked drawings carry the names: find yours on the map. Hover a drawing and its row lights up in "
            .. "the tables; hover a row and its drawing lights up on the map.",
    },
    {
        title = "Your spot in 3D",
        -- (in the room: all of it, the eye in its corner included)
        anchor = function()
            if in3D() then return canvas().frame end
            return W().mode2d, W().mode3d
        end,
        skip = no3D,
        text = "In 3D, the eye button (My spot) stands you on your spot at eye height, looking at the boss: the fight "
            .. "as you will see it. Right-drag looks round; with several jobs, the eye again goes to the next one.",
        hint = "Click 3D, then the eye in the room's top right corner.",
        done = function() return in3D() and cam().dist < 3 end,
        stay = true,
        ghost = function()
            if not in3D() then return { from = { W().mode3d, 0.5, 0.5 } } end
            local eye = v3().eyeBtn
            return eye:IsShown() and { from = { eye, 0.5, 0.5 } } or nil
        end,
    },
    {
        title = "The tables",
        anchor = function() return blocks().scroll end,
        side = "left",
        text = "Who does what. Hover a cell for the details: who fits the slot, which boss abilities a row is "
            .. "about, when it applies.",
    },
    {
        title = "Phases",
        anchor = function() return W().tabs[1], W().tabs[#st().strat.p] end,
        side = "bottom",
        skip = function() return #st().strat.p < 2 end,
        text = "Each tab is a phase of the fight, with its own map and jobs. Look at them all: your job can change.",
    },
    {
        title = "In the raid",
        text = "Near the boss a slim panel shows your jobs and follows the tracked tables you are in: whose kick it "
            .. "is, your misdirect done, your curse up. The raid leader's also follows the tables they are not in. "
            .. "It stays through the fight and fades after it.",
    },
    {
        title = "Try it before the raid",
        anchor = function() return W().moreBtn end,
        side = "bottom",
        text = function()
            return "Practice, in the " .. glyph(24) .. " menu, plays a minute of the fight with your jobs: that panel, "
                .. "whose kick it is, marks on what you target. Demo players take the other slots; stand at a target "
                .. "dummy and use your real spells.\n\nNext: where strategies live, and building one together."
        end,
    },
}

---------------------------------------------------------------------------
-- The library (Raids > Strategies)
---------------------------------------------------------------------------

local function L() return ns.StrategiesUI:GetLibrary() end

local library = {
    {
        title = "Raids and bosses",
        anchor = function() return L().list.frame end,
        text = "Every strategy belongs to a boss. Pick a raid or a boss to see its strategies; the numbers count "
            .. "them, and an orange count is unsaved work of yours.",
    },
    {
        title = "Finding one",
        anchor = function() return L().search, L().by end,
        side = "bottom",
        text = "Search by strategy, boss or raid name. By narrows the list to your own, the ones shared with you, "
            .. "or one guild member's.",
    },
    {
        title = "The strategies",
        anchor = function() return L().detail.list.frame end,
        side = "right",
        text = "A click on a card opens the strategy to look at. The pencil changes yours and the ones shared with "
            .. "you. The ... menu has the rest: Copy makes any strategy yours, and Delete is for the owner, the Guild "
            .. "Master and the guild council.\n\nYour drafts sit on top of their raid, tagged Draft: continue or "
            .. "discard them.",
    },
    {
        title = "Building together",
        anchor = function() return L().detail.list.frame end,
        side = "right",
        text = "Collaborators, in the ... menu of a strategy you own, picks the guild members who build it with you: "
            .. "they change it like you do. Share puts a link to a strategy in the chat.\n\nWhen two of you edit at "
            .. "the same time the board goes live: you see each other's changes and selections as they happen. A "
            .. "card shows who is editing right now.",
    },
    {
        title = "Your turn",
        anchor = function() return L().detail.newBtn end,
        side = "left",
        text = "New strategy starts a real one for the boss picked on the right. It opens with the boss' map and its "
            .. "creatures in place, like the practice board did.\n\nThis tutorial stays under the ? beside it, and "
            .. "under the board's ?, chapter by chapter.",
    },
}

---------------------------------------------------------------------------

-- Gets the practice board on the screen in a mode. pre runs before the mode changes, post after it.
local function board(mode, pre, post)
    return function()
        if not B():OpenSandbox(BOSS, true) then return false end
        if pre then pre() end
        if st().mode ~= mode then B():SandboxMode(mode) end
        if post then post() end
        return true
    end
end

-- The board as most chapters start: the first page, the select tool, on the 2D map.
local function onMap()
    firstPage()
    selectTool()
    flat()
end
local function flatFirst()
    firstPage()
    flat()
end

local BUILD, RAID = "Building a strategy", "Running a raid"

ns.Tour:Register("strategy", {
    title = "Strategy board",
    menuGroups = { [BUILD] = "Tutorial: building a strategy", [RAID] = "Tutorial: running a raid" },
    offerTitle = "New to the strategy board?",
    offerText = "Take the guided tour on a practice board: building a strategy, the room in 3D, assigning a raid, "
        .. "reading a plan. Stop whenever you like; the chapters you finished are remembered. Nothing you do there is "
        .. "saved or shared.",
    host = function() return W() end,
    open = board("edit"),
    alive = function() return B():IsShown() and st().sandbox == true and pg() ~= nil end,
    chapters = {
        { key = "basics", group = BUILD, title = "The basics", enter = onMap, steps = basics },
        { key = "drawing", group = BUILD, title = "Drawing on the map", enter = onMap, steps = drawing },
        -- (it starts on the map too: its first step is the switch into the room)
        { key = "room3d", group = BUILD, title = "The room in 3D", enter = function() onMap(); roomMap() end,
          steps = room3d },
        { key = "jobs", group = BUILD, title = "Jobs and links", enter = onMap, steps = jobs },
        { key = "helpers", group = BUILD, title = "In-fight helpers", enter = onMap, steps = helpers },
        { key = "assign", group = RAID, title = "Assigning a raid", open = board("fill", seed), enter = flatFirst,
          steps = assigning },
        { key = "read", group = RAID, title = "Reading a plan", open = board("view", seed, fillNames),
          enter = flatFirst, steps = reading },
        { key = "library", group = "The library", title = "Finding and sharing strategies",
          host = function() return L() end,
          open = function()
              B():Close()
              ns.MainFrame:Open("raids")
              ns.RaidsUI:SetView("strategies")
              return L() ~= nil and L():IsVisible()
          end,
          alive = function() return L() ~= nil and L():IsVisible() end,
          steps = library },
    },
})
