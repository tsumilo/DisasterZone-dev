# Raid Trainer renderer v2: findings behind the spec

Produced by the investigation workflow of 2026-10-03. The spec is spec.md next to this file.

## WoW API research (classic_anniversary client)

### Q1a. SetVertexOffset vertex index constants (confirmed)

UPPER_LEFT_VERTEX = 1, LOWER_LEFT_VERTEX = 2, UPPER_RIGHT_VERTEX = 3, LOWER_RIGHT_VERTEX = 4. These are global constants defined in this client's FrameXML, so the code can use the names instead of literal numbers.

Evidence: Blizzard_FrameXMLBase/Classic/Constants.lua lines 631-634: 'UPPER_LEFT_VERTEX = 1; LOWER_LEFT_VERTEX = 2; UPPER_RIGHT_VERTEX = 3; LOWER_RIGHT_VERTEX = 4;' (classic_anniversary branch)

Source: https://raw.githubusercontent.com/Gethe/wow-ui-source/classic_anniversary/Interface/AddOns/Blizzard_FrameXMLBase/Classic/Constants.lua

### Q1b. SetVertexOffset signature, units, limits, availability in this client (confirmed)

Present in this client: TextureBase:SetVertexOffset(vertexIndex luaIndex, offsetX uiUnit, offsetY uiUnit). GetVertexOffset(vertexIndex) and ClearVertexOffsets() also exist. Offsets are in uiUnit, the region's own coordinate space, so they scale with the region's effective scale, the same as SetPoint offsets. Each offset is relative to that corner's un-offset position. No clamping or range is documented, and I found no report of limits. Added in patch 7.2.0.

Evidence: SimpleTextureBaseAPIDocumentation.lua: SetVertexOffset args '{ Name = "offsetX", Type = "uiUnit" }'. Wiki: 'Patch 7.2.0 note=Added.'

Source: https://raw.githubusercontent.com/Gethe/wow-ui-source/classic_anniversary/Interface/AddOns/Blizzard_APIDocumentationGenerated/SimpleTextureBaseAPIDocumentation.lua ; https://warcraft.wiki.gg/wiki/API_TextureBase_SetVertexOffset

### Q2a. Which diagonal splits an offset quad into two triangles; is texture interpolation affine (likely)

The split runs along LL to UR. The two triangles are (UL, LL, UR) and (LL, UR, LR), which matches triangle-strip order 1, 2, 3, 4. The wiki's example image moves only UL by (-20, 20). In it, the lower-right half (the mushroom stem and the right and bottom borders) is untouched and only the upper-left half is sheared. A UL-LR split would have skewed the stem too. Texture interpolation is plain affine within each triangle: there is no perspective divide. So collapsing LR onto UR gives one true triangle (UL, LL, UR) plus a degenerate one, which is what UI.lua does. The LR texcoord should equal the UR texcoord.

Evidence: Visual inspection of API_TextureBase_SetVertexOffset_04.png (offset -20,20 on UL): the lower-right triangle is undistorted. The API has no per-vertex w/q (see Q9).

Source: https://warcraft.wiki.gg/images/API_TextureBase_SetVertexOffset_04.png ; https://warcraft.wiki.gg/wiki/API_TextureBase_SetVertexOffset

### Q2b. Does the client cull or clip a texture by its un-offset rectangle; reports of vertex-offset textures disappearing or jittering (unknown)

Unknown. Nothing documented, and no community report found either way for vertex-offset textures. Related known bugs: SetClipsChildren causes flickering in some setups (7.2.5+). With several Model children, only the first visible one clips correctly. Since 11.0 a PlayerModel inside a SetClipsChildren frame changes position and size and loses its frame-level stacking. In the Trainer, the 1x1 base rects sit exactly on the BOTTOMLEFT corner of the clipping view. If the client tests the un-offset rect against the clip or screen rect, a rounding at that edge could drop a triangle. That is a cheap hedge to remove (anchor at CENTER).

Evidence: Reports: 'If I set it to false, no flickering occurs' (55680); clipping works for 'the first visible Model child' only (57285); in 11.0 'the position and size of the model changes' (344697).

Source: https://wowinterface.com/forums/showthread.php?t=55680 ; https://www.wowinterface.com/forums/showthread.php?t=57285 ; https://wowinterface.com/forums/showthread.php?p=344697

### Q3. Pixel snapping: SetSnapToPixelGrid / SetTexelSnappingBias in this client, defaults, effect (likely)

Both exist in this client, along with IsSnappingToPixelGrid and GetTexelSnappingBias. According to Blizzard developer TheDanW, with snapping on 'the texture's verts will be rounded to the nearest pixel during the rendering phase'. A bias above 0 implies snapping and makes the renderer pick single texels instead of blending them (a sharpening effect). The default for new textures is not documented; the argument default shown is false. However, Blizzard explicitly turns snapping off (snapToPixelGrid=false, texelSnappingBias=0) on rotated, animated or deformed textures in many templates and in NineSliceUtil.DisableSharpening, which strongly suggests it is ON by default. For a bent triangle this means every vertex jumps by up to half a pixel as the camera moves, and texels are picked rather than filtered, which shows up as shimmer or crawl. The Trainer's UI.lua never disables it; Azeromon/UI.lua does.

Evidence: TheDanW blue post (2018-10-02) quoted on the wiki: verts 'rounded to the nearest pixel'. NineSlice.lua 221-222: 'piece:SetTexelSnappingBias(0); piece:SetSnapToPixelGrid(false);'. NamePlates.xml behindCameraIcon rotation=45 uses snapToPixelGrid=false.

Source: https://warcraft.wiki.gg/wiki/API_TextureBase_SetSnapToPixelGrid ; https://raw.githubusercontent.com/Gethe/wow-ui-source/classic_anniversary/Interface/AddOns/Blizzard_SharedXML/NineSlice.lua

### Q4a. Draw order inside the same frame, same draw layer and same sublevel; sublevel range (likely)

Sorting is strata, then frame level, then draw layer (BACKGROUND, BORDER, ARTWORK, OVERLAY, HIGHLIGHT), then sublevel -8..7. Two textures with identical frame, layer and sublevel have no documented order. Community reports describe them coming out in an apparently random order, so creation order cannot be relied on. FontStrings always draw above textures in the same layer.

Evidence: Wiki Region:SetDrawLayer: 'Integer between -8 and 7 (inclusive)'. Forum: 'layer in a different random order every time I draw'; 'effects of omitting these is undocumented'.

Source: https://warcraft.wiki.gg/wiki/API_Region_SetDrawLayer ; https://warcraft.wiki.gg/wiki/Layer ; https://www.wowinterface.com/forums/showthread.php?t=54860

### Q4b. Frame levels: range, equal-level siblings, Raise/SetToplevel effects on children, SetFixedFrameLevel (confirmed)

Levels run 0 to 10000. Since 7.0.3 levels no longer compress or change automatically, and frames always sort by the level that was set. Equal-level siblings have no documented order (unknown, do not rely on it). When a parent's level changes, every descendant shifts by the same amount. A shift below 0 wraps to 10000; behaviour above 10000 is undocumented (probably a clamp, which would collapse the stack onto one level). SetToplevel(true) makes the frame raise itself when clicked or shown, which shifts all children, and implicitly enables render-layer flattening. Raise() lifts the frame above the others in its strata. SetFrameLevel, SetToplevel, Raise and SetFixedFrameLevel are protected only for secure frames in combat, so they are fine for addon frames. GetRaisedFrameLevel exists. SetFixedFrameLevel(true) keeps a frame's level from following its parent.

Evidence: Frame Strata wiki: 'lower than 0 it will instead be set to 10000'. TheDanW IRC 2016: levels 'now always stay what you set them to'. SetToplevel: 'Render layer flattening will also be implicitly enabled.'

Source: https://warcraft.wiki.gg/wiki/Frame_Strata ; https://warcraft.wiki.gg/wiki/API_Frame_SetFrameLevel ; https://warcraft.wiki.gg/wiki/API_Frame_SetToplevel

### Q4c. Cost of SetDrawLayer / SetParent per frame (unknown)

No profiling data found. Both change which sorted region list and batch a texture belongs to, so they are very likely costlier than setters that only change geometry (SetVertexOffset, SetTexCoord). The Trainer currently calls them whenever a triangle's BSP rank or lifted state changes.

Evidence: No source found; this is an inference from the engine's sorted layering model.

Source: n/a

### Q4d. Render-layer flattening (SetFlattensRenderLayers), and that SetClipsChildren and SetToplevel turn it on (confirmed)

Flattening composites all descendant textures and fontstrings of a frame into a single render layer. It exists to stop unrelated overlapping frames from drawing interleaved. SetClipsChildren(true) and SetToplevel(true) enable it implicitly; GetEffectivelyFlattensRenderLayers reports it. The Trainer's view and arena frames call SetClipsChildren(true), so the whole room plus the ModelScene sit inside a flattened subtree. SetIsFrameBuffer (render a flattened frame to an offscreen buffer) also exists. It only changes how alpha is composited and does nothing for depth.

Evidence: Wiki SetClipsChildren: 'Enabling clipping also enables render layer flattening'. SetFlattensRenderLayers: 'all descendant textures and fontstrings will be flattened'.

Source: https://warcraft.wiki.gg/wiki/API_Frame_SetClipsChildren ; https://warcraft.wiki.gg/wiki/API_Frame_SetFlattensRenderLayers ; https://warcraft.wiki.gg/wiki/API_Frame_SetIsFrameBuffer

### Q5. SetClipsChildren semantics and cost (likely)

It takes a single boolean and clips descendants to the frame's rectangle. Clipping follows the parent/child hierarchy: Freedoom Arcade relies on it for textures anchored anywhere inside its view. Whether it is a GPU scissor or geometric clipping is undocumented. Known bugs: flicker (7.2.5+); with several Model children only the first clips; in 11.0 a model inside a clip frame changes position and size and loses its stacking. The workaround reported for models is giving each model its own wrapper frame. No data on the cost of many clipping frames.

Evidence: SimpleFrameAPIDocumentation.lua: SetClipsChildren(clipsChildren bool). Model clip bugs in the threads listed under Q2b.

Source: https://raw.githubusercontent.com/Gethe/wow-ui-source/classic_anniversary/Interface/AddOns/Blizzard_APIDocumentationGenerated/SimpleFrameAPIDocumentation.lua ; https://www.wowinterface.com/forums/showthread.php?t=57285

### Q6a. Do ModelScenes take part in the frame-level and draw-layer order like regions (can several be stacked and interleaved with texture frames)? (likely)

Yes, very likely. ModelScene has SetDrawLayer(layer) and GetDrawLayer() returning layer and sublevel, and Model has SetModelDrawLayer. Blizzard's LFG frame places a ModelScene at its parent's frame level (useParentLevel) with drawLayer=BACKGROUND, so the model draws under the parent's OVERLAY textures. The catalog shop uses drawLayer=BORDER at frameLevel 500. A scene therefore sorts as one unit at its (frame level, draw layer). This matches the user's confirmation that room frames above the scene hid the player. Several scenes at different levels with identical camera settings should interleave with texture frames between them. Each scene renders and depth-tests only its own actors, so actors in different scenes never depth-test against each other.

Evidence: LFGFrame.xml line 104: ModelScene 'useParentLevel="true" drawLayer="BACKGROUND"'. API docs list ModelScene SetDrawLayer and GetDrawLayer.

Source: https://raw.githubusercontent.com/Gethe/wow-ui-source/classic_anniversary/Interface/AddOns/Blizzard_GroupFinder/Classic/LFGFrame.xml ; https://raw.githubusercontent.com/Gethe/wow-ui-source/classic_anniversary/Interface/AddOns/Blizzard_APIDocumentationGenerated/FrameAPIModelSceneFrameDocumentation.lua

### Q6b. Performance of many ModelScene / PlayerModel frames (likely)

Expensive on the modern engine. A well-known UI author reported in Oct 2024 (retail 11.0) that a single rendered model can cost about 10 FPS because of an engine bug, and that 3D portraits on unit frames and nameplates 'tank your performance'. Use a handful of scenes, not dozens. Unverified on Anniversary.

Evidence: Luckyone on X: one rendered model 'can be as bad as a 10 FPS loss'.

Source: https://x.com/Luckyone961/status/1843256715917050331

### Q6c. ModelScene camera API in this client and Project3DPointTo2D conventions (likely)

Available: SetCameraPosition(x,y,z), SetCameraOrientationByYawPitchRoll(yaw,pitch,roll), SetCameraOrientationByAxisVectors(forward xyz, right xyz, up xyz), getters GetCameraForward/Right/Up/Position, SetCameraFieldOfView(fov) in radians, Set/GetCameraNearClip and FarClip, SetViewInsets, SetViewTranslation. Project3DPointTo2D(x,y,z) returns point2DX, point2DY, depth and is flagged MayReturnNothing, so it can return nil (likely for points behind the camera). Blizzard's catalog-shop code treats the result as frame-local UI units with origin at BOTTOMLEFT and y up: it subtracts it from frameWidth*0.5 and feeds it to SetPoint('BOTTOMLEFT'). Whether the FOV is vertical or horizontal is not documented anywhere I found.

Evidence: Docs: Project3DPointTo2D 'MayReturnNothing = true'; FOV 'Field of view in radians'. Blizzard_CatalogShop_Model.lua ~line 316-380 uses the projected points with SetPoint BOTTOMLEFT.

Source: https://raw.githubusercontent.com/Gethe/wow-ui-source/classic_anniversary/Interface/AddOns/Blizzard_APIDocumentationGenerated/FrameAPIModelSceneFrameDocumentation.lua ; https://raw.githubusercontent.com/Gethe/wow-ui-source/classic_anniversary/Interface/AddOns/Blizzard_CatalogShop/Blizzard_CatalogShop_Model.lua

### Q7. Can an addon load a custom .m2 shipped in its own folder? (unknown)

No definitive evidence either way. The API exists: ModelSceneActor SetModelByPath(asset FileAsset, useMips) and Model:SetModel(ModelAsset). The wiki text that says it is 'theoretically' possible dates from the MPQ era. The only modern attempt found (SetModel('Interface\\AddOns\\MyAddon\\MyModel')) failed and the thread was closed without an answer. No known addon ships a model. Modern M2s reference their skin and texture files by FileDataID, which loose files do not have. Treat a depth-buffered room shipped as a custom model as unavailable unless a 1-minute in-game test proves otherwise.

Evidence: Docs list SetModelByPath. WoWInterface t=57884: the user tried an addon-path SetModel 'without success', no resolution.

Source: https://raw.githubusercontent.com/Gethe/wow-ui-source/classic_anniversary/Interface/AddOns/Blizzard_APIDocumentationGenerated/FrameAPIModelSceneFrameActorBaseDocumentation.lua ; https://www.wowinterface.com/forums/showthread.php?t=57884 ; https://warcraft.wiki.gg/wiki/API_Model_SetModel

### Q8. Can a ModelScene or Model render a WMO, or is there any other engine-side way to draw world geometry in the UI? (likely)

Nothing found. Actor and model setters take M2-type assets (file ID, path, creature display ID, unit). No Blizzard UI code loads a WMO into a model frame. SetModelByFileID with a wrong file ID crashes the client with an access violation (WoWUIBugs #67), so probing WMO file IDs is dangerous. No other API draws static world geometry inside the UI.

Evidence: WoWUIBugs #67: SetModelByFileID with an invalid ID crashes the client. The project already found that WMO geometry cannot be loaded.

Source: https://github.com/Stanzilla/WoWUIBugs/issues/67

### Q9. Any API for perspective-correct mapping or for arbitrary textured triangles? (confirmed)

No. The complete TextureBase API in this client offers SetTexCoord (4 args documented; the 8-arg corner form works but is undocumented), SetVertexOffset, SetRotation, SetGradient (per-corner colour), masks, tiling, nine-slice and sprite-sheet cells. There is no w/q or homogeneous coordinate, no mesh or polygon widget, and Line is only a thick textured segment. The only ways to approximate perspective are subdividing triangles or using constant-depth strips. Freedoom Arcade, a Doom renderer inside a WoW addon, draws walls as one strip per screen column and floors as horizontal spans, where depth is constant per strip and affine mapping is therefore exact.

Evidence: Full function list in SimpleTextureBaseAPIDocumentation.lua and SimpleTextureAPIDocumentation.lua. Freedoom README: floors are 'one strip per horizontal span'.

Source: https://raw.githubusercontent.com/Gethe/wow-ui-source/classic_anniversary/Interface/AddOns/Blizzard_APIDocumentationGenerated/SimpleTextureBaseAPIDocumentation.lua ; https://github.com/petllama/FreedoomArcade

### Q10. Relative costs of setters for 1000-3000 textures per frame (likely)

No real profiling numbers found. What exists: (a) a Legion-era report that SetTexture with a changing large file was very slow because it re-read from disk (since fixed), and that Hide/Show cycles every frame were costly because hidden textures were thought to free resources; (b) AVR drew 'hundreds of triangles' updated every frame without trouble; (c) Freedoom Arcade's working backend redraws hundreds to about a thousand textures per frame. It caches every value and calls SetTexture, SetPoint, SetSize, SetVertexColor and Show/Hide only when the value changed; it calls SetTexCoord every frame. It never moves textures between frames or layers: each sort layer is its own frame at baseLevel+l and every texture sits at ARTWORK sublevel 0.

Evidence: WoWInterface t=53777: 'Unnecessary Hide(texture) calls every OnUpdate' hurt performance. Freedoom src/draw.lua: 'if t.dtex ~= tex then ... SetTexture'.

Source: https://www.wowinterface.com/forums/showthread.php?t=53777 ; https://www.wowinterface.com/forums/showthread.php?t=36189 ; https://github.com/petllama/FreedoomArcade/blob/main/src/draw.lua

### Extra: engine generation of this client (likely)

The classic_anniversary API documentation includes 12.0-era functions (Model:SetUseGBuffer, added in 12.0.0, and housing frame APIs). So the Anniversary client runs the current retail engine and UI renderer, and retail-era renderer bugs (model or clip issues from 11.0) are likely to apply.

Evidence: SimpleModelAPIDocumentation.lua lists SetUseGBuffer; the wiki says 'Patch 12.0.0 note=Added.'

Source: https://warcraft.wiki.gg/wiki/API_Model_SetUseGBuffer

### Extra (project code, read-only): likely cause of 'background drawn in front of foreground' in the current renderer (likely)

UpdateOcclusion (UI.lua ~line 451) lifts only the room triangles that are nearer than a model and overlap its screen box into overFrames above the ModelScene. Every non-lifted triangle stays below the scene. So a non-lifted triangle that is nearer than a lifted one and overlaps it on screen gets painted over by it: for example, a near floor or rail triangle in front of a lifted pillar, outside the model's box. That breaks the painter's (BSP) order and shows background in the foreground. The pop is made worse because occlusion only updates every 3rd frame (occTick % 3) and the lift is a per-triangle heuristic based on one depth and a bounding box. Pieces also inherit the over state. Each lift change costs a SetParent.

Evidence: UI.lua UpdateOcclusion: 'if not force and st.occTick % 3 ~= 0 then return end'; 'local isOver = covers and not blocked'; PlaceTex(..., isOver).

Source: C:/World of Warcraft/_anniversary_/Interface/AddOns/DisasterZone/Games/Trainer/UI.lua

### Custom models

No definitive evidence either way, so for planning treat it as not available. SetModelByPath and Model:SetModel exist in this client's API documentation, but the only modern attempt found failed without resolution and no known addon ships a model. Modern M2s reference their skin and texture files by FileDataID, which loose addon files lack. WMOs cannot be loaded either, and probing with bad file IDs can crash the client. A depth-buffered room shipped as a model is therefore not a realistic plan unless a one-line in-game test proves otherwise: put a stock M2 copied into the addon folder and call SetModelByPath on an actor.

### Recommendations

- DO keep the painter's order strict. A texture may share (frame, draw layer, sublevel) only with textures it can never overlap on screen: coplanar triangles of one BSP node, or pieces of one triangle. Never give two room frames the same frame level. Order inside one slot, and between equal-level frames, is undefined.
- DON'T lift a subset of triangles above the ModelScene with a per-triangle heuristic, as UpdateOcclusion does now. It paints lifted far triangles over nearer non-lifted ones, which is the 'background in front of foreground' symptom. Instead, cut the BSP back-to-front sequence at the model's position: locate the model's point or leaf in the same BSP traversal, and send everything drawn after it to the frames above the scene. With models at clearly different depths, use 2-4 stacked ModelScenes (one per depth band, identical camera) with the room frames in between, and put each actor in the scene for its band. Recompute every frame, not every 3rd.
- DO call tx:SetSnapToPixelGrid(false) and tx:SetTexelSnappingBias(0) once on every room texture, piece texture and floor-mark Line, guarded with 'if tx.SetSnapToPixelGrid'. Blizzard does this for every deformed or rotated texture, the default is very likely ON, and snapping rounds each vertex to a pixel and picks single texels, which causes shimmer and crawl.
- DO anchor the 1x1 base rect of each bent texture well inside the visible view (for example the scene's CENTER, with offsets measured from there), not exactly on the BOTTOMLEFT edge of a clipping frame. Any culling or clipping test on the un-offset rect then always passes.
- DO clip in Lua instead of relying on the engine. Clip each triangle against the near plane in 3D before projecting (with UVs interpolated in world space), and against the view rectangle in screen space (Sutherland-Hodgman). Never project points behind or very near the camera. Project3DPointTo2D may also return nothing for such points: handle nil.
- DON'T put the ModelScene under a SetClipsChildren ancestor if it can be avoided. Model-in-clip-frame bugs are reported on the 11.x engine this client uses. If the room textures need clipping, use a clipping frame that holds only the texture frames, or clip in Lua and drop SetClipsChildren.
- DO keep texture positions in the draw order fixed and move the data instead. Pool textures per draw slot, where a slot is a fixed frame, layer and sublevel; each frame, assign the k-th visible node's triangles (in BSP order) to slot k's pool. Then only SetTexture (guarded by a cached-path compare), SetTexCoord and SetVertexOffset change, never SetParent or SetDrawLayer. Freedoom Arcade does it this way (one frame per sort layer, all textures at ARTWORK 0).
- DO cache every setter's last value and call it only on change (SetTexture, SetVertexColor, SetVertexOffset, Show). Hide only the pool tail above this frame's high-water mark; never Hide/Show the same texture within a frame.
- DO keep perspective error pinned to the world. Compute every piece vertex's UV from its true 3D point, never by interpolating UVs in screen space. For the large floor, consider Doom-style constant-depth strips: cut along screen lines of equal view depth, where affine mapping is exact along the strip. Subdivision only reduces the error, it never removes it.
- DO use the named constants UPPER_LEFT_VERTEX..LOWER_RIGHT_VERTEX. Draw the triangle as UL, LL, UR (the split runs LL to UR), set LR to the same position as UR, and give LR the same texcoord as UR in the 8-argument SetTexCoord.
- DO keep the frame-level span small and well below 10000. Check at Show() that rootLevel + highest offset (about 160 now) is below 10000. Avoid making the trainer root toplevel: a raise shifts all children, and a level pushed past 10000 is undefined (probably clamped, which would merge the stack).
- DON'T create many ModelScenes. Each one costs a separate render pass, and retail reports describe roughly 10 FPS per rendered model. 1-4 scenes are fine; one scene per actor is not.
- DON'T plan on custom .m2 or WMO rendering for the room. There is no evidence it works, and a bad file ID crashes the client. Keep the software renderer.
- OPTIONAL, cheap in-game checks to remove the remaining unknowns, each a /run one-liner. (1) Print tx:IsSnappingToPixelGrid() on a fresh texture. (2) Draw one triangle clockwise and one counter-clockwise to confirm the UI never back-face culls. (3) Move a bent texture's 1x1 base rect just outside a clipping parent and see whether the triangle vanishes.

## Audit of the v1 renderer (measured)

### D1 (severity 5, high): Lifting room triangles above the models breaks the back-to-front order, and the 'is it in front' test uses a per-triangle average depth

Location: UI.lua UpdateOcclusion 451-536 (test at 511, isOver 520-525, pieces re-placed 527-535); DrawMesh 782-788 (odepth[i] = mean of the corner depths clamped to NEAR, line 786; bbox from all drawn pieces); PlaceTex 376-383; CreateScene 1265-1272 (overFrames at levels +71..+134, above the ModelScene at +70 and every meshFrame)

Symptom: (a) background drawn over foreground; also the player or other models hidden by floor or walls that are behind them

Mechanism: 1) A lifted triangle goes to overFrames, so it is painted after every non-lifted triangle, whatever the BSP order says. Any nearer non-lifted triangle that overlaps it on screen ends up underneath it. 2) The covers test is d < mo.depth - 0.5 with d = (max(da,2)+max(db,2)+max(dc,2))/3. In Vashj the generator keeps triangles up to 40 yd long (max_edge = 40), so tier strips run from behind the camera to 20-25 yd. Their clamped average comes out at 8-13 yd, under the player's 14.65 yd, so they count as 'in front of the player'. Tier floors also pass low > z + 0.4 because the tiers between camera and player are higher than his feet. They get lifted whole. Examples measured: tri 3721 with corner depths 23.9/-3.9/-3.4 (avg 9.3) and tri 1536 with 0.3/20.6/-0.3 (avg 8.2). 3) Whether a strip lifts depends on which diagonal the generator cut the quad along: the half with two corners behind the camera lifts, the other half (avg about 16) does not. Lifted and unlifted strips therefore interleave. Measured offline (real addon code in the harness, exact pinhole camera, 700x500 view, default chase camera): Vashj, 12 of 40 random views have more than 500 wrong pixels, up to 52k px (15% of the view). Running across the tiers, 46-58k wrong pixels on every frame. The player model is covered by lifted surfaces lying behind him in 3 of 40 Vashj views (up to 2.6k px of his ~5.9k px box). Teron: 4 of 40 views have more than 500 px wrong. With the bug fixed, model occlusion itself would be about right (Teron: every should-hide pixel is lifted correctly).

Fix: Replace the depth heuristic with the exact BSP rule. Triangle T (plane n, vertex A; the camera is on its front because it faces the camera) can hide model M only if M's feet and head points are on the back of T's plane: n·(P−A) < −0.2. Decide this per piece, not per source triangle. That fixes the long-strip errors and makes the 'floor above the feet' guess unnecessary. To keep the order, the clean fix is to drop the lift: give each unit its own ModelScene and fit it into the BSP order. Run the unit's point down the tree (same side tests as the traversal) to get its exact rank among the nodes. When slots are assigned, start a new room frame at that rank and set the unit's ModelScene frame level between the two room frames (room frames on even levels, unit scenes on odd ones). Changing a scene's level each frame is cheap, and a unit never has to change scene, so no model reloads. Minimum fallback that keeps one scene: plane test, per-piece lift, and close the lifted set under 'drawn later in BSP order and overlapping on screen'.

### D2 (severity 5, high): Subdivision stops on a depth ratio alone: screen size is ignored, so long or near pieces stretch by tens of pixels

Location: UI.lua DrawMesh: RATIO/LEVELS at 645; whole-triangle test at 741; Cut 700-707; generator gen_trainer_heights.py line 51 (vashj max_edge = 40.0) and emit 248-261

Symptom: (c) stretching and warped textures, worst on long tier edges, step faces and anything near the camera

Mechanism: A Texture maps its picture affinely, so along an edge with corner depths d1, d2 and screen length L the texture is off by up to L·|d1−d2|/(2(d1+d2)). The rule hi <= 1.3·lo caps that only at 0.065·L, and nothing limits L. Floor straight ahead at a 1.3 ratio (f = 571 px): 8.1 px at 7 yd, 5.7 at 10, 3.8 at 15, 2.8 at 20, 1.9 at 30 (with a vertical FOV, f = 408: 5.8 / 4.1 / 2.7 / 2.0 / 1.4). A long tier strip or riser crossing the view passes the test while 900-1000 px long; measured: main textures with ratio 1.23-1.29 and 900-1000 px long are off by 40-60 px. Pieces near the camera (depth 2.5-5, ratio ≤ 1.3) can be 1500-4000 px wide; measured errors 70-233 px. Over 40 random views per room: Vashj mean 4.6 px, p95 14.6, max 29 per view; Teron mean 2.4, p95 7.4, max 17. 59% of piece pixels belong to pieces whose error exceeds 5 px.

Fix: Split on screen-space error: e_edge = L_px·|d1−d2|/(2(d1+d2)), split while the largest e_edge > τ, keeping the longest-edge midpoint so cuts stay put on the floor. Decide per EDGE (an edge's split depends only on its own two endpoints), so both triangles sharing it split it the same way (see D5). Simulated texture counts on the same views (near-plane clipping at 0.5 included): τ = 1 px costs 2.2x the current count in Vashj and 3.8x in Teron; τ = 2 px costs 1.5x / 2.3x; τ = 4 px costs about the same as today in Vashj (1402 vs 1218 textures) with a worst error of about 4 px instead of 30-230. Also lower Vashj max_edge to about 9 yd (Teron already uses 9) so per-triangle decisions (D1, D2) stay local.

### D3 (severity 5, high): Near plane at 2 yd, pieces still crossing it after 8 halvings are dropped, and the chase camera has no collision with the room

Location: UI.lua DrawMesh: NEAR = 2 at 592; vertex loop 599-603; Cut 699 (dropped when wholly behind) and 704-706 (dropped while still crossing at level 0); triangle loop 735/741. PlaceCamera 177-185 (camera always dist·cos(pitch) behind and dist·sin(pitch)+2.2 up, never tested against geometry)

Symptom: (b) triangles disappearing and holes: a full-width band near the bottom of the view or wherever geometry passes close to the camera, showing what lies behind it ('I see the background from the foreground')

Mechanism: 1) Surfaces between the engine's near clip (0.5) and 2 yd are never drawn. A piece that still crosses 2 yd after 8 levels is dropped whole, so the missing band reaches about 2.8 yd. 2) The camera sits 6.34 yd above the player's floor and 13.4 yd behind him. In Vashj's stepped room it often skims or enters the higher tiers. Distance from the camera to the nearest room triangle over 400 random spots and facings: under 2 yd in 14% (Vashj) and 10% (Teron), under 0.5 yd in 5% / 2%. Measured holes: rows 348-382 across all 700 columns (tri 4444, depths 1.49/4.4/0.21, drawn with 19 of its pieces missing); rows 234-396, 13.7k px; with the camera in a wall, 35k px of holes plus 101k px where far surfaces show through. Of 40 random default-camera Vashj views, about 6 (15%) lose more than 10k px this way. Teron: 0 of 40 at the default camera, 1 of 40 with free pitch and zoom.

Fix: (a) Clip each triangle exactly at the near plane in camera space (Sutherland–Hodgman, giving 1-2 triangles) and subdivide what is left; never drop. Use NEAR of about 0.3-0.5 to match SetCameraNearClip(0.5). (b) Add camera collision as the real client does: cast from the player's head point (tx, ty, tz) to the wanted camera spot against the room mesh (BSP ray traversal, or a grid of all triangles; mesh.grid holds only floors). Put the camera about 0.5 yd before the first hit, pull it in fast and let it back out slowly.

### D4 (severity 4, high): Subdivision level switches at a hard threshold every frame: texture pops while running

Location: UI.lua DrawMesh: Cut 696-726, whole-triangle test 741 (the level is recomputed from scratch each frame, with no hysteresis or blending)

Symptom: (c)/(d) textures jumping or swimming while running even though the cuts themselves are stable

Mechanism: When a triangle crosses ratio 1.3, it goes from one texture (midpoint off by 0.065·L) to two halves (midpoint exact, rest off by about 0.016·L). The picture inside jumps by about 0.065·L in a single frame: 6-8 px for a floor triangle at 7-13 yd (L of 90-125 px), up to 40-65 px for long strips. Measured at 7 yd/s and 60 fps (0.117 yd per frame), tracking the same surface point between frames: Vashj tiers, 7-20 triangles change level every frame, and on about a quarter of frames 1.5-3.8% of visible pixels jump by more than 3 px (largest jump 18-33 px). Teron hall: 4 of 23 frames have 1.4-2% of pixels jumping by more than 3 px. Frames without a switch move under 0.7 px at p99.

Fix: Keep each triangle's or edge's split state from the last frame and add hysteresis: split at τ, merge back at 0.6τ. Blend the new midpoint's texture coordinate from the parent's affine value (lerp(t1, t2, d1/(d1+d2)), the texel the unsplit texture showed there) to the true midpoint (t1+t2)/2 as the error grows from τ to about 1.5τ. The corner positions are exact, so no frame shows a jump.

### D6 (severity 4, high): Whole strips toggle between lifted and not lifted in single frames (lift flicker)

Location: UI.lua UpdateOcclusion 500-526 (one yes/no decision per source triangle, hard threshold at 511, rerun every frame while moving and every 3rd frame while still, 455)

Symptom: (d) large patches flickering in front of or behind each other while moving; models popping in and out from behind surfaces

Mechanism: The lift is one bit per source triangle, decided from an average depth that drifts every frame and bounding boxes that span the screen. As the player moves, a 40-yd strip crosses d < mo.depth − 0.5 and its 30-50 pieces jump between the under and over frames at once. Measured running on the Vashj tiers: the lifted texture count goes 223→177, 199→152→194, and the wrong-pixel area changes by 9-10k px in one frame (48.7k → 57.6k, 58.6k → 49.1k).

Fix: Goes away with D1's plane test plus per-piece decisions, or with models fitted into the BSP order. If some lift stays, add a margin on both sides of the threshold so a decision does not flip back and forth.

### D5 (severity 3, high): Texture seams where neighbouring triangles or pieces are cut to different levels

Location: UI.lua DrawMesh Cut 696-726 (each triangle decides its own levels); generator build_bsp/split_tri 119-137 (BSP splits already leave T-junctions)

Symptom: (c) tears in the texture along triangle edges that move and change as you run

Mechanism: With affine mapping, two textures sharing an edge show the same texels along it only if the edge's split points match on both sides. Cut decides per triangle, so one side may halve a shared edge while the other does not (likewise BSP splits that left T-vertices on unsplit neighbours). The texture breaks along the edge by the difference of the two affine errors. Measured: 3.1% of neighbouring pixel pairs on the same plane jump by more than 2 px across such edges, 1.2% by more than 5 px, worst 40 px.

Fix: Decide splits per edge (D2) so shared edges split identically. Recognise shared edges in PrepareMesh by vertex index, or by position where the BSP left T-vertices. Each triangle then uses the standard refinement pattern for 1, 2 or 3 split edges. Lower τ also shrinks the leftover seams.

### D7 (severity 3, low): Opaque WMO materials drawn with the UI's default alpha blending

Location: UI.lua DrawMesh 749-759 (main textures) and Piece 678-685 (piece textures: SetTexture with no SetBlendMode); generator build_mesh 207-218 reads only the texture, never MOMT blend or shader

Symptom: (a)/(b) surfaces that look see-through: what is behind shows through a nearer surface

Mechanism: Every material used by both rooms has blend mode 0 (opaque) and none is two-sided (flags 0). A Texture defaults to BLEND, so any alpha below 1 in the BLP makes the triangle partly transparent. Vashj materials 5/25 (file 126729, 282 triangles, shader 5 = environment-mapped metal) are the likeliest case, because that shader normally stores a reflection mask in the alpha channel. Not verified: the BLPs are not in the dev kit and I did not download them.

Fix: Call tx:SetBlendMode('DISABLE') on every room texture whose material blend is 0 (main and pool textures), and use 'ALPHAKEY' for blend 1. Write the blend mode per texture from the generator (it is in MOMT). Costs nothing.

### D8 (severity 2, medium): Some models show through walls because one model in front blocks the whole triangle's lift

Location: UI.lua UpdateOcclusion 508-520 (blocked = overlaps any model it is not in front of; isOver = covers and not blocked)

Symptom: (a) a raider or boss visible through a pillar or wall

Mechanism: One bit per triangle cannot both hide model A (behind it) and stay under model B (in front of it). Any overlap with B leaves the triangle unlifted, so A shows through. Vashj also has failures from the average depth (long triangles) and from the player's box. Measured (box approximation of the bodies): Vashj, 3.2k of 39.8k should-hide model pixels wrongly shown, 6 of 40 views over 200 px; Teron almost none (95 px).

Fix: Same fix as D1: models fitted into the BSP order, or per-piece decisions.

### D9 (severity 2, medium): Camera height follows the floor under the player with no smoothing

Location: UI.lua PlaceCamera 181 (tz = GroundZ(p.x, p.y) + 2.2, every frame)

Symptom: (d) the whole view jolts while running over Vashj's tiers

Mechanism: T.HeightFn blends the 0.5-yd height grid over 1 yd, so crossing one tier (about 0.75 yd) lifts the camera 0.75 yd in about 0.14 s at 7 yd/s, once per tier. It also moves the camera's height against the tier edges, which adds to the near-plane cases in D3.

Fix: Smooth the camera's target height with a critically damped spring (about 0.15-0.25 s) separately from the model's z.

### D10 (severity 2, low): Assumptions about the engine's projection that cannot be checked offline

Location: UI.lua DrawMesh probes 568-580 (basis measured 10 yd ahead along cam.f); Project 165-174; PlaceCamera 183-184

Symptom: (c)/(d) the room swimming relative to the models while moving, if either assumption is wrong

Mechanism: The Lua projection is exact only if the ModelScene's projection is a pinhole whose axis is exactly cam.f, and if Project3DPointTo2D already reflects SetCameraPosition and SetCameraOrientationByYawPitchRoll from the same frame. A pitch-convention difference, or a camera matrix that lags one frame, would make the probes measure a different camera than the one cam.* describes. The room would then shift by turn rate × f (about 20-30 px at a 0.05 rad/frame turn) and warp with depth, while culling, BSP and near decisions use cam.*. The mock cannot test this because its projection ignores orientation.

Fix: Add an in-game self-check: each frame, project one extra point (for example 40 yd ahead, 6 right, 3 up) with the Lua basis and with Project3DPointTo2D, and print a warning once if they differ by more than 1 px. If they do, calibrate the focal lengths once and compute the projection analytically, or probe after a frame delay.

### D11 (severity 1, high): Draw-order capacity nearly full (latent)

Location: UI.lua MESH_FRAMES/MESH_SLOTS 369-370, slotStep 410, squeeze 612, SlotAt 919

Symptom: (a)/(d) would show up after the rooms are regenerated with more nodes

Mechanism: 64 frames × 48 = 3072 slots. A step of 2 (a room for the node plus one for mark lines) needs at most 1536 nodes; Vashj has 1511 (98% full). Above 1536 the step drops to 1, so mark lines tie with floor slots (order undefined). Above 3072 the squeeze makes nodes that are not coplanar share a slot, which breaks the order.

Fix: Make the generator fail above 1536 nodes, or add frames as needed. Lowering max_edge (D2) will raise the node count, so plan the capacity together with that change.

### Performance hotspots

- UI.lua DrawMesh main textures 761-765 and Piece 688-691: SetVertexOffset ×4 for every visible texture on every moving frame: Teron hall running: ~2450 main textures + ~80 pieces = 10.1k SetVertexOffset per frame; Vashj tiers: ~350 main + ~1300 pieces = 6.6k; random Vashj views average 523 main + 724 pieces (up to 2.1k textures). Every call also forces the client to rebuild that region's geometry. Idea: Cut what is drawn: frustum-cull by BSP node bounds and coarsen far geometry with the screen-space error rule (D2). Skip textures whose four offsets did not change by more than 0.05 px (helps when only turning slightly or standing still with the camera moving a little).
- UI.lua Piece 677-694: pooled textures re-set up from scratch each frame: Per piece per frame: SetVertexColor + 8-arg SetTexCoord + Show (even when already shown) + PlaceTex. That is about 3×(700-1700) wasted calls, and because pool entries are handed out in a different order each frame, 100-240 SetParent + 130-280 SetDrawLayer per frame on the Vashj tiers. Idea: Keep piece textures per (source triangle, path through the cuts) so the same piece keeps its texture, coordinates, colour and parent across frames. Skip Show when already shown and cache the last texture coordinates and colour.
- UI.lua DrawMesh Lua work 593-636, 731-799: Every vertex projected each moving frame (Vashj 4642, Teron 3927; about 25 flops plus 6 table writes each); all 6.5k / 4.8k triangles go through the facing test even when off-screen; all ~1.5k BSP nodes visited three times each (side recomputed on every visit); Cut recursion over 1.3-1.7k pieces; a string.format key and a new basis table every frame. Roughly 1-3 ms of Lua per moving frame. Idea: Store bounding spheres per node and skip whole subtrees that are off-frustum or behind the near plane, projecting only the vertices those nodes use. Compute side once per node visit. Reuse the basis table.
- UI.lua UpdateOcclusion 451-536 run with force after every redraw: Loops nOcc (800-1300) triangles × the screen columns each touches × the models in those columns, then calls PlaceTex on every piece because piecesDirty is set on every redraw (about 1.3k Lua calls on the Vashj tiers even when nothing changed). Idea: Only re-place pieces whose triangle's lift actually flipped (keep a list). This becomes unnecessary if models are fitted into the BSP order (D1).
- Rendering in the client: 64 + 64 frames × 3 layers × 16 sublevels, 9-19 texture files interleaved in painter order: About 1.3-2.6k separately transformed regions per frame with almost no batching (texture file and draw layer change from one triangle to the next): likely around 1-2.5k UI draw calls per frame. This is probably part of the frame-rate loss the user noticed; the client's real cost per call is not known offline. Idea: Fewer, larger textures where the error rule allows. Group consecutive same-file triangles inside a node or slot. Avoid splitting the order across overFrames (D1).

## Reference renderer (dev/tools/render_check.py)

Run from C:/Users/emilo/CDLoot-dev/dev: `luaenv/Scripts/python.exe tools/render_check.py --enc teron|vashj|both [--png OUTDIR] [--quick] [--json FILE] [--size 600x400] [--scale 1] [--poses name1,name2] [--no-walk] [--compare OLD_metrics.json]`.
- Full run on both rooms: 140 frames in about 107 s (26 poses, 2 walks of 30 frames, 2 actor walks of 27 frames).
- `--quick` uses 4 poses per room, an 8-frame walk and a 9-frame actor walk.
- `--png` writes, per pose, `<room>_<pose>_sheet.png` (painter | truth | diff with the numbers), the three full-size PNGs, walk sheets, the walk's largest-jump sheet, the actor-walk worst-frame sheet, `README.txt` (legend and metric definitions) and `metrics.json` (every number, including per-frame data for the walks).
- `--compare OLD.json` prints per-pose deltas, which is how a renderer rewrite should be judged against this baseline.
- Regression test: `luaenv/Scripts/python.exe tests/games/test_render_check.py` (8 cases, about 2 s).

### Metrics

What each image is:
- PAINTER is built only from recorded widget state. It takes every shown texture and line under the view frame and works out:
  - its rectangle, resolved from its anchors;
  - its vertex offsets (UL=1, LL=2, UR=3, LR=4);
  - its texture file and texture coordinates, with affine interpolation like the GPU with w = 1;
  - each quad as two triangles split along LL-UR.
  Regions are sorted by strata, frame level (ties broken by creation order and flagged), draw layer, sublevel, and clipped by SetClipsChildren frames. The ModelScene is drawn at its own level, with each actor as an upright billboard (height from u.plate, then u.tall, then PLATE_HEIGHT, else 2.6 yd; width max(1.2, min(2*radius, 0.6*height)); starting 0.15 yd above the feet), depth-tested among actors only.
- TRUTH is a z-buffer of the same mesh (scene = (x, mirror*y, z)), with:
  - back faces culled using the renderer's own counter-clockwise test in arena space;
  - near clip at the scene's near clip (0.5) by Sutherland-Hodgman;
  - perspective-correct texture coordinates (1/d, u/d, v/d affine on screen);
  - exactly the mock ModelScene projection, verified against Project3DPointTo2D to 1e-6 at start;
  - the billboards depth-tested against the room.
- Both are rendered at 1 pixel per UI unit (600x400).

Surface rule (no affine tolerance needed):
- Each painted room region is matched to the mesh triangle it is a piece of, using only its API data:
  - same texture file;
  - its 3 corner texture coordinates lie inside that triangle's texture triangle;
  - those points of the triangle, projected, land on its 3 screen corners within 1 UI unit.
- An affinely mapped piece of triangle T can only ever show texels of T, so distortion never makes a correct pixel count as wrong.
- A pixel is RIGHT if its region's triangle is the truth triangle at that pixel or at one of its 8 neighbours (edge tolerance).
- Regions that match no triangle (degenerate texture coordinates, a few dozen per frame, about 2%) fall back to: same file, and texel inside the truth triangle's texture triangle (barycentric >= -0.002).
- The synthetic test proves that whole triangles drawn with p95 133 px of affine error still give 0% wrong.

Metrics (percentages are of truth-covered pixels):
- wrongSurfacePct is split into:
  - wrongPaintedOverPct: the truth triangle was drawn at that pixel and then covered by something behind it, i.e. an order error. wrongOverAboveScenePct is the part drawn by regions above the ModelScene level.
  - wrongMissingPct: the truth triangle was never drawn there, so what lies behind shows through.
  - wrongUnmatchedPct.
- holesPct: truth has room surface, the painter draws nothing.
- extraPct: the painter draws where the truth has nothing.
- misplacement (right pixels): the texel's texture coordinate is mapped back through its triangle to a 3D point, projected, and the screen distance to the pixel is measured. This is exact rather than a Jacobian linearisation. p95, p99 and max are reported, in UI units, which equal pixels at UI scale 1.
- popMaxPx / popP99Px (walks): change of a pixel's misplacement vector between consecutive frames, over pixels with the same truth triangle that are right in both frames.
- flickerPct: such pixels whose class (right / wrong / hole) changes between frames.
- actorErrPct: billboard pixels where "actor visible" differs between painter and truth, split into hidden-wrongly and shown-wrongly.
- ambiguousPct: pixels whose final colour depends on an order WoW does not define (same frame + layer + sublevel, or different frames with the same strata + level). Ties between two lines are counted separately as ambiguousLinesPct.
- seeThroughPct (poses only): view pixels where a back face is nearer than any front face, meaning the camera is inside or behind geometry.
- diagonalSensitiveQuads.
- shownTextures: shown textures that carry a room texture file.
- apiCallsPerFrame: widget calls in a frame where the camera moved (each pose is reached from a 0.004 rad turn), with a breakdown.
- luaMsPerFrame: wall time of one panel tick in mock Lua.

### Mock changes

All edits are in dev/tools/wowmock/objects.lua and are backwards compatible.
(a) ModelScene:Project3DPointTo2D is now a real pinhole camera that honours SetCameraOrientationByYawPitchRoll(yaw, pitch, roll):
- forward = (cos p cos y, cos p sin y, -sin p), so positive pitch looks down, as Blizzard's orbit camera counts it.
- Horizontal FOV; screen-right = up x forward (still -y for a camera looking along -x); screen-up = forward x right; roll turns right towards up.
- Returns (sx*es, sy*es, depth), or nil behind the camera.
- With no orientation set, or exactly (math.pi, 0, 0), the original formula runs bit for bit (Azeromon uses this; a test asserts exact equality).
- Side effect for the trainer: its Calibrate now flips cam.mirror to -1 in the mock (the projection is mirrored by design). The trainer suites still pass.
(b) Line:SetStartPoint / SetEndPoint now record {relativePoint, relativeTo, x, y}, with GetStartPoint / GetEndPoint added; they were no-ops before.
- New M.region_rect(region, origin, memo) resolves rectangles from any SetPoint / SetAllPoints anchors plus SetSize, per axis (two edges, or edge/centre plus size), honouring SetScale. It returns nil when there are no anchors, a cycle, or an unresolvable chain.
- New M.line_points(line, origin) resolves line end points.
- GetLeft / GetBottom stay the 0 stubs.
- Everything else the tool reads was already recorded: voff, texcoord, texture, vcolor, layer/sublayer, parent, level, strata, shown, clips, thickness/color, and the actors' pos/scale/shown.
(c) M.set_api_count(tbl) / M.set_api_count(nil) counts every widget method lookup (one per obj:Method() call) by name. It is off by default, guarded by an upvalue nil check. ModelScene actors are plain tables and are not counted.

### Baseline of the v1 renderer

| room | pose | wrong % | holes % | misplacement p95 px | max px | pop px | actor err % | shown | API calls | mock ms |
|---|---|---|---|---|---|---|---|---|---|---|
| teron | open_floor_north | 0 | 0 | 3.5 | 10 | None | 0 | 2509 | 10521 | 13.6 |
| teron | cam_behind_west_wall | 0 | 0 | 6.2 | 12.7 | None | 0 | 1466 | 6380 | 5.2 |
| teron | facing_west_wall | 0 | 0 | 5.1 | 13.8 | None | 0 | 296 | 1500 | 6.5 |
| teron | behind_west_pillar | 0 | 0 | 4.1 | 11.9 | None | 0.06 | 1606 | 8129 | 13.4 |
| teron | camera_in_pillar | 0 | 0 | 5.7 | 16.9 | None | 0.41 | 1264 | 8179 | 15 |
| teron | pit_up_west_steps | 0 | 0 | 7.7 | 17.3 | None | 0 | 913 | 4060 | 7.6 |
| teron | rim_down_into_pit | 0 | 0 | 8.1 | 13.7 | None | 0 | 509 | 2365 | 5.2 |
| teron | grazing_pitch_005 | 0.05 | 0 | 3.7 | 10.5 | None | 3.94 | 2553 | 11124 | 20.6 |
| teron | overhead_pitch_12 | 0 | 0 | 6.4 | 9.9 | None | 0 | 179 | 1004 | 5.6 |
| teron | close_dist5_east_rim | 0.4 | 0 | 4.8 | 8.8 | None | 0 | 814 | 5423 | 12.1 |
| teron | far_dist30_pit | 0 | 0 | 3.9 | 6.2 | None | 0.24 | 1024 | 6171 | 10.7 |
| teron | nw_statue | 0 | 0 | 5.8 | 8.6 | None | 0 | 999 | 5663 | 10.6 |
| teron | past_east_pillar | 0 | 0 | 4 | 7.8 | None | 0.05 | 2420 | 10294 | 10 |
| teron | facing_south_wall | 0 | 0 | 6.3 | 11.8 | None | 0 | 268 | 1565 | 5.9 |
| teron | walk (30 frames, mean) | 0.01 | 0 | 4.3 | 12.5 | 15.4 | 0.12 | 2342 | 10006 | 12.9 |
| teron | actor_walk (27 frames, camera still, mean) | 0.05 | 0 | 3.8 | 11.3 | 1.5 | 0.79 | 2546 | 275 | 0.9 |
| vashj | platform_north | 0 | 0 | 4.2 | 10.1 | None | 0 | 1694 | 8509 | 18.5 |
| vashj | bottom_up_platform | 0.23 | 0 | 22.1 | 38 | None | 0 | 1702 | 9553 | 15.1 |
| vashj | bottom_cam_behind_wall | 0.15 | 0 | 23.5 | 37.8 | None | 0 | 1722 | 9595 | 11.4 |
| vashj | next_to_generator | 0 | 0 | 7.7 | 14.1 | None | 0 | 1016 | 7147 | 25.3 |
| vashj | ring_east_steps | 0 | 0 | 8.3 | 21.2 | None | 0 | 384 | 2440 | 15.3 |
| vashj | overhead_pitch_12 | 0 | 0 | 22.5 | 30.3 | None | 0 | 28 | 2125 | 7.1 |
| vashj | far_dist30 | 0.01 | 0 | 16.1 | 23 | None | 0 | 2092 | 10905 | 19.8 |
| vashj | grazing_pitch_005 | 0 | 0 | 5.7 | 16.8 | None | 0 | 826 | 6249 | 15.7 |
| vashj | close_dist5_edge | 0 | 0 | 9.6 | 20 | None | 0 | 425 | 3160 | 15.9 |
| vashj | sw_pipe | 0 | 0 | 12.8 | 37 | None | 0 | 716 | 4143 | 13.3 |
| vashj | facing_south_wall | 1.92 | 0 | 23.2 | 39.6 | None | 0 | 222 | 2172 | 8.8 |
| vashj | ring_south_pitch_08 | 0 | 0 | 9.9 | 17.9 | None | 0 | 173 | 2917 | 18.9 |
| vashj | walk (30 frames, mean) | 0.14 | 0 | 6.3 | 15.1 | 14.8 | 0 | 1978 | 10321 | 23.2 |
| vashj | actor_walk (27 frames, camera still, mean) | 2.94 | 0 | 11.4 | 18.2 | 0 | 33.87 | 1063 | 377 | 1.7 |

### Observations

- The draw order from the BSP tree is correct. In the mock, with an honest pinhole camera, 22 of the 26 poses have 0.00% wrong surfaces and holes are 0% everywhere. Every 'painted over' pixel found (wrongOverAboveScenePct equals wrongPaintedOverPct in every pose) comes from triangles that UpdateOcclusion moved into the frames above the ModelScene. Lifting breaks the order: a lifted far triangle paints over every nearer triangle that stayed below. Example, Teron close_dist5_east_rim (0.40%): step tread 861 (z -2.04, 11.7-13.7 yd away) was lifted to level 80 and is drawn over the nearer, higher tread 837 (level 11). A separate check showed the BSP ranks themselves were right (802 before 809 in a Vashj case). In game there are more moving units than in these static poses, so there would be more lifts. This is the most likely source of 'background rendered in front of foreground'.
- Lifting also gets actors wrong. Vashj actor walk (camera still on the north ring): in every frame 32% of the actor pixels (mostly the player) are covered by a wedge of the big slanted wall piece next to him. That triangle's average depth is nearer than the player, but the part that overlaps him is behind him. In Teron's actor walk, the raider walking behind the west pillar shows through the pillar's edge for several frames (up to 3.5% of actor pixels). In Teron grazing_pitch_005, raiders down in the pit show their legs through the pit rim (3.9% shown wrongly): rim triangles that overlap the player's large screen rectangle count as 'blocked' and are never lifted.
- Flicker with a still camera: in the Vashj actor walk, thin step-edge strips are lifted over the nearer floor (1-6.4% painted over per frame). The lifted set changes exactly every third frame (frames 2, 5, 8, 11, ...), because the occlusion pass only runs every third frame while the view stands still. Up to 5.25% of room pixels flip between right and painted-over from one frame to the next. This matches 'sometimes triangles disappear'.
- Stretching is real and large, and worst in Vashj's room:
- Misplacement p95 is 3.5-8 px in Teron and 4-23.5 px in Vashj; max is up to 17 px in Teron and 40 px in Vashj.
- In vashj_bottom_up_platform, 77% of room pixels are more than 5 px off. The step strip's dark texture line sits about 18 px from where it belongs.
- vashj_overhead_pitch_12 draws the floor as only 28 big textures (p95 22.5 px). The texture grid lines visibly kink at triangle edges.
- Cause: RATIO 1.3 limits the depth ratio inside a piece, not its error on screen. Big triangles at a similar depth (Vashj's 30-40 yd step strips, floors seen from above, the near step in vashj_sw_pipe) are drawn whole with tens of pixels of affine error. A rewrite needs a screen-space error bound.
- Instability while moving: walking 0.25 yd per frame, the largest jump of where a texel is drawn between two frames is 15.4 px in Teron and 14.8 px in Vashj (p99 7.6 / 7.3 px). teron_walk_pop_sheet.png shows a band of floor between the near floor and the pillar bases where pieces are re-cut from one frame to the next. That is the 'warping triangles as I run around' report.
- Triangles near the camera are lost: DrawMesh drops everything nearer than 2 yd (NEAR = 2), while the scene's own near clip is 0.5. In vashj_facing_south_wall, 0.55% of pixels are 'never drawn': step treads crossing the camera plane are dropped and the tread behind shows through. In the same pose 1.37% is painted over by lifted treads. With the default distances this is rare for floors, because the bottom of the screen looks at floor 4-8 yd away.
- The camera goes through walls: seeThroughPct is 100% in teron_cam_behind_west_wall (camera outside the hall west of the wall), 80.5% in teron_rim_down_into_pit (camera at x 2.3, 12 yd up, inside the west wall's thickness) and 100% in vashj_facing_south_wall (camera under the steps). Painter and truth agree there because both cull back faces, so you see the room through the wall. There is no camera collision. This is a second plausible source of 'I see what's in the background from the foreground'.
- Cost of a moving camera: up to about 11,000 widget calls per frame in big views. In open_floor_north, 10,036 of 10,521 are SetVertexOffset (4 per shown texture, 2,509 textures). Cutting many triangles adds 450-860 SetTexCoord calls per frame (camera_in_pillar, close_dist5) plus reparenting and draw-layer changes. With a still camera it is 275-377 calls per frame. Mock Lua time is 5-27 ms per frame, indicative only.
- Nothing else came up: room order ambiguity is 0 (every BSP node has its own slot). Only segments of one floor mark overlap in the same slot (ambiguousLinesPct up to 0.26% in the Vashj walk), which is harmless. No quad has 4 distinct corners, so the choice of diagonal never matters. Holes and extra pixels are 0 everywhere.
- The mock did not reproduce everything the user reports. It shows the four mechanisms above (lifting order errors and flicker, the 2 yd near cut, the camera through walls, large affine error with 15 px pops). If the real client deviates from the pinhole camera, WoW's documented draw order or the recorded vertex offsets (pixel snapping, sorting quirks), the tool cannot see it. Worst-frame sheets to look at: teron_close_dist5_east_rim, teron_grazing_pitch_005, teron_walk_pop, teron_actor_walk_worst, vashj_bottom_up_platform, vashj_overhead_pitch_12, vashj_facing_south_wall and vashj_actor_walk_worst (each with suffix _sheet.png).

### Limitations

- It only judges what the mock records. The camera is the mock's pinhole by construction (horizontal FOV, mirrored screen-right, positive pitch looking down), and the truth uses the same projection, so it cannot detect differences between the real client's projection and that model. Other real-client effects are not modelled: pixel snapping, texture filtering and mipmaps, blend and alpha, scissor details, undocumented order of frames with equal levels.
- There are no real WMO textures (only minimap BLPs are in the dev kit). The pictures use made-up checker textures, one hue per file. The metrics compare texture coordinates, not colours.
- Actors are billboards, not models: 1.2-5 yd wide, height from the sim's plate/tall values, the bottom 0.15 yd ignored. The 0.15 yd margin exists because the height grid puts feet about 0.08 yd under the mesh floor in the pit. Spell-effect actors are ignored, so actorErrPct measures occlusion of those rectangles.
- Floor-mark lines appear in the painter picture but are excluded from the room metrics. Their 3D positions are not in the API data, so there is no truth for them. The HUD (plates, unit frames, minimap) is excluded entirely.
- The 1-pixel neighbour tolerance hides errors narrower than 1 px.
- About 2% of regions per frame (pieces of triangles with degenerate texture coordinates) match no triangle and fall back to the texture rule. With the same file and overlapping texture coordinates, a wrong surface could pass there. Misplacement is not measured for degenerate-UV triangles.
- The truth culls back faces like the renderer, so the camera clipping through walls is not counted as wrong. It is only flagged by seeThroughPct.
- popMaxPx mixes re-cut pops with the smooth drift of the affine error over 0.25 yd. Each pose is reached from a 0.004 rad turn, so the API counts are for a moving camera, not for a big jump.
- luaMsPerFrame is Python wall time around one mock tick in lupa (plain Lua 5.1), with API counting on. The mock's widget calls cost differently from the client's; for example, the mock's SetParent is linear in the number of children.
- The view is fixed at 600x400 UI units, because the mock lays the panel out at 280x360. The real size depends on the window, and pixel numbers scale with it.
- The poses are static apart from the walks, with the raid standing where the sim put it at about 1 ms (Teron) or 4 s (Vashj) of play. In the Vashj actor walk the walking raider is mostly behind the nearby structure; its large actor error is the player being covered, plus the lifted strips that change as the raider moves.

## 2026-10-04: models whose origin is not at their feet

- In-game report: the Shield Generators in Lady Vashj's room were drawn over the steps in front of them. Each generator is placed at its database height (+1.10), but its model (coilfang_floor_light.m2, file 191730, scale 2.1) has its origin mid-height: the M2 box is z -1.354 .. 2.138 model units, so the pedestal ends 2.84 yd lower, at -1.74, just under the ring's floor (-1.41). The copies keep only what lies higher than an occluder's feet (+ FOOT), and the feet were the database height, so every step and ring edge lower than +1.2 was never copied over a generator.
- render_check could not see it: the mock returned no box for file models and the truth billboard started at the actor's origin. The mock now returns the real M2 box for file 191730, the A record carries the box bottom, and the truth starts there. New v2 pose vashj generator_over_steps (down the north-west steps looking up at a generator): actor error 12.1% before (the four generators 4-100% wrong), 0.7% with the occluder starting where the model's box ends (no lower than the floor under it), 0.0% after also giving the family A box its 2 px margin at the bottom when the camera is under the feet (the other sides already had it).
- Left as it is: the 0.33 yd of pedestal under the floor still shows (0.7-1.0% of the generators' pixels in next_to_generator and far_dist30). The client's depth buffer hides it; the copies would have to paint floor over the pedestal's front to hide it here.
- Second in-game report the same day (looking up the steps): the steps now hid the generators' bodies but not their pedestals. That is what the occluder looks like with no usable box from the client (feet at the origin, +1.10; radius 0): with the camera under +1.1 everything above it is copied over, the pedestal below is not. Whether 2.5's GetActiveBoundingBox reports nothing for a file model or something else is not known. The generator now carries its M2 box (u.box), merged with whatever the client reports; test a_generator_stands_on_the_ring_for_the_copies_even_when_the_client_reports_no_box.
