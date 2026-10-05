# 3D board depth research (2026-10-05)

Output of a 13-agent research / design / judge workflow on how to get exact room-vs-model depth in the strategy
board's 3D view (Render3D/*, UI/StrategyMap3D.lua). Sections: research reports, designs, judges, final recommendation.
Treat 'verified' claims as checked against files or docs, the rest as hypotheses for the in-game probe.

## Research

### I read Blizzard's generated API docs from Gethe/wow-ui-source and parsed them into signature lists

I read Blizzard's generated API docs from Gethe/wow-ui-source and parsed them into signature lists. The branch `classic_anniversary` is at HEAD commit 1463c686, labelled "2.5.6 (69795)". That build matches the installed client exactly: C:\World of Warcraft\.build.info says 2.5.6.69795 and DisasterZone.toc says Interface 20506. So the user's client is 2.5.6, not 2.5.5. There is no `bcc` branch any more. I also compared other branches: `classic_era` (1.15.9.70003), `classic` (5.5.4.70032, MoP Classic), `live` (retail 12.1.0) and the last 2.5.5 commit (1e059c80, build 68101).

The ModelScene, ModelSceneActor, Model, Texture and Frame APIs are identical in 1.15.9, 2.5.6 and 5.5.4. Retail adds only SetModelByHyperlink and front-end lobby functions.

What exists for depth, all per scene and nothing per actor:
- SetCameraNearClip / SetCameraFarClip
- Project3DPointTo2D, which returns x, y and a depth
- SetViewInsets / SetViewTranslation (2D viewport only)
- fog near/far/color
- ModelScene:SetDrawLayer
- **SetAllowOverlappedModels(bool)**, a ModelScene setting that explains nothing about itself

What does not exist anywhere in these branches' docs: per-actor clip planes, stencil, raycast or mouse intersection (CalculateMouseIntersection), unproject, camera or projection matrices, and any control of depth writing or depth testing. TextureBase has nothing depth-related.

Model loading: actors have SetModelByFileID and SetModelByPath (verified). Blizzard uses them for spell-effect models and housing decor. Blizzard's housing doc says some decor assets are "not supported by UI model scenes", so a WMO room file most likely cannot be loaded into an actor. Animation: actors only have SetAnimation(anim, variation, animSpeed, animOffsetSeconds) — speed 0 freezes the pose, as Blizzard does with SetAnimation(0,0,0,0) — plus SetPaused (new in 2.5.6) and PlayAnimationKit. Particles: actors only have SetParticleOverrideScale; old-style Model frames have SetParticlesEnabled, SetSequenceTime, SetModelDrawLayer and fog, but no near/far clip.

Three things the addon has never tried could change the depth picture; all need in-game tests:
1. **SetAllowOverlappedModels(true)** (the addon never calls it). Blizzard turns it on for shop product-card scenes and the full-screen scripted-effects scene; the shop code cites bug CLASS-44103. If it gives each scene its own depth, frame level would decide again and the failed depth-slicing idea could work.
2. **Frame:SetIsFrameBuffer**. The wiki says the frame is "rendered to its own framebuffer prior to being composited". A separate depth buffer would isolate scenes the same way.
3. **OffScreenFrame** (TakeSnapshot / ApplySnapshot: render to a texture). It is documented, but nothing in Blizzard code uses it and it is unclear whether addons can create one.

The user's own finding that all scenes share one depth buffer (default mode, same clip range) also allows an exact approach: a "proxy" scene drawn below the room textures. Its models would match the room geometry. They would write depth, be painted over by the room, and per-pixel hide boss pixels behind walls in a scene drawn above. That needs a simple opaque primitive model; spells/unitcube.m2 (fdid 167145) is listed on wago, but I have not checked that it exists in the 2.5.6 client.

Room doodads are M2 files and can be added as real actors with SetModelByFileID. They would then occlude bosses correctly per pixel and fill in the missing props.

I edited nothing in the addon. Scratch work (doc parser, downloaded docs, shallow clones) is in C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\aa52e4d4-c087-4769-a09e-98ce81f5d755\scratchpad (ann_sigs.txt has every parsed signature).

- [verified] The installed client is 2.5.6.69795 (Interface 20506), not 2.5.5. It is exactly the build of Gethe/wow-ui-source branch classic_anniversary HEAD (commit 1463c686, '2.5.6 (69795)'), so those docs describe this client.: C:\World of Warcraft\.build.info: 'wow_anniversary ... 2.5.6.69795'. DisasterZone .toc: '## Interface: 20506'. GitHub API commits?sha=classic_anniversary: HEAD 1463c686270b6c64e2c5c228f447c4597c0f8ba6 '2.5.6 (69795)'; last 2.5.5 commit is 1e059c80 '2.5.5 (68101)'. Current branches: automation, beta, classic_anniversary, classic_beta, classic_era(_ptr), classic(_ptr), classic_titan, forever, live, ptr, ptr2. There is no 'bcc' branch. classic_era = 1.15.9 (70003), classic = 5.5.4 (70032), live = 12.1.0 (69933). (https://api.github.com/repos/Gethe/wow-ui-source/commits?sha=classic_anniversary ; C:\World of Warcraft\.build.info)
- [verified] Complete ModelScene method list for 2.5.6 (also inherits all Frame, ScriptRegion and Region methods).: ClearFog(); CreateActor(name, template); GetActorAtIndex(index); GetAllowOverlappedModels()->bool; GetCameraFarClip(); GetCameraFieldOfView() (radians); GetCameraForward()->x,y,z; GetCameraNearClip(); GetCameraPosition(); GetCameraRight(); GetCameraUp(); GetDrawLayer()->layer,sublevel; GetFogColor()->r,g,b; GetFogFar(); GetFogNear(); GetLightAmbientColor(); GetLightDiffuseColor(); GetLightDirection(); GetLightPosition(); GetLightType()->ModelLightType? (Directional=0, Point=1); GetNumActors(); GetViewInsets()->uiRect; GetViewTranslation()->x,y; IsLightVisible(); Project3DPointTo2D(x,y,z)->point2DX,point2DY,depth [MayReturnNothing]; SetAllowOverlappedModels(bool); SetCameraFarClip(f); SetCameraFieldOfView(fov); SetCameraNearClip(n); SetCameraOrientationByAxisVectors(fx,fy,fz,rx,ry,rz,ux,uy,uz); SetCameraOrientationByYawPitchRoll(y,p,r); SetCameraPosition(x,y,z); SetDesaturation(s); SetDrawLayer(layer); SetFogColor(r,g,b); SetFogFar(f); SetFogNear(n); SetLightAmbientColor(r,g,b); SetLightDiffuseColor(r,g,b); SetLightDirection(x,y,z); SetLightPosition(x,y,z); SetLightType(t); SetLightVisible(visible=false); SetPaused(paused, affectsGlobalPause=true); SetViewInsets(uiRect); SetViewTranslation(x,y); TakeActor(). Line numbers: Project3DPointTo2D L331, SetAllowOverlappedModels L350, SetCameraFarClip L359, SetCameraNearClip L378, SetDrawLayer L435, SetFogNear L464. (https://github.com/Gethe/wow-ui-source/blob/1463c686270b6c64e2c5c228f447c4597c0f8ba6/Interface/AddOns/Blizzard_APIDocumentationGenerated/FrameAPIModelSceneFrameDocumentation.lua)
- [verified] Complete ModelSceneActor method list (ActorBase + Actor) for 2.5.6. There is no per-actor clip, stencil, depth, draw-layer, non-uniform scale or animation-time function.: ActorBase: ClearModel; GetActiveBoundingBox()->bottom,top (L18); GetAlpha; GetAnimation; GetAnimationBlendOperation; GetAnimationVariation; GetDesaturation; GetMaxBoundingBox (L97); GetModelFileID; GetModelPath; GetModelUnitGUID; GetParticleOverrideScale()->number?; GetPitch; GetPosition; GetRoll; GetScale; GetSpellVisualKit; GetYaw; Hide (L243); IsLoaded (L251); IsPreferringModelCollisionBounds; IsShown; IsUsingCenterForOrigin()->x,y,z; IsVisible; PlayAnimationKit(kit, isLooping=false) (L318); SetAlpha(a) (L328); SetAnimation(anim, variation?, animSpeed=1, animOffsetSeconds=0) (L337); SetAnimationBlendOperation(None=0|Anim=1) (L349); SetDesaturation; SetGradientMask(g0..g3); SetGradientMaskWithDyes(d0?,d1?,d2?); SetModelByCreatureDisplayID(id, useActivePlayerCustomizations=false)->success (L390); SetModelByFileID(asset:FileAsset, useMips=false)->success (L405); SetModelByPath(asset:FileAsset, useMips=false)->success (L420); SetModelByUnit(unit, sheathe=false, autoDress=true, hideWeapons=false, usePlayerNativeForm=true, holdBowString=false, customRaceID?)->success; SetParticleOverrideScale(scale?) (L456); SetPitch; SetPlayerModelFromGlues(...); SetPosition(x,y,z); SetPreferModelCollisionBounds(bool) (L504, 'use the collision bounds of models for sizing and centering'); SetRoll; SetScale(s) (L523, single number); SetShown(show=false); SetSpellVisualKit(id=0, oneShot=false) (L541); SetUseCenterForOrigin(x,y,z) (L551); SetYaw; Show; StopAnimationKit; TryOn(...). Actor: AttachToMount; CalculateMountScale; DetachFromMount; Dress; DressPlayerSlot; GetAutoDress; GetItemTransmogInfo(List); GetObeyHideInTransmogFlag; GetPaused()->paused,globalPaused (L125); GetSheathed; GetUseTransmogChoices/Skin; IsGeoReady() (L178); IsSlotAllowed/Visible; ResetNextHandSlot; SetAutoDress; SetItemTransmogInfo; SetObeyHideInTransmogFlag; SetPaused(paused, affectsGlobalPause=true) (L261); SetSheathed; SetSheathedCategory; SetUseTransmogChoices/Skin; Undress; UndressSlot; UseUnitSheatheCategory. XML actor scripts: OnLoad, OnUpdate, OnModelCleared, OnModelLoading, OnModelLoaded, OnAnimFinished (UI.xsd L1105-1116). (https://github.com/Gethe/wow-ui-source/blob/1463c686270b6c64e2c5c228f447c4597c0f8ba6/Interface/AddOns/Blizzard_APIDocumentationGenerated/FrameAPIModelSceneFrameActorBaseDocumentation.lua and .../FrameAPIModelSceneFrameActorDocumentation.lua)
- [verified] Complete Model (SimpleModel) method list. PlayerModel, DressUpModel, TabardModel, CinematicModel and ModelFFX add their own sets on top. Model frames have SetModelDrawLayer, fog, SetParticlesEnabled, SetSequenceTime and AdvanceTime, but no near/far clip and no Project3DPointTo2D.: SimpleModelAPI: AdvanceTime (L10); ClearFog; ClearModel; ClearTransform; GetCameraDistance/Facing/Position/Roll/Target; GetDesaturation; GetFacing; GetFogColor->r,g,b,a; GetFogFar; GetFogNear; GetLight->enabled,ModelLight; GetModelAlpha; GetModelDrawLayer->layer,sublayer; GetModelFileID; GetModelScale; GetPaused; GetPitch; GetPosition; GetRoll; GetShadowEffect; GetViewInsets; GetViewTranslation; GetWorldScale; HasAttachmentPoints; HasCustomCamera; IsUsingModelCenterToTransform; MakeCurrentCameraCustom; ReplaceIconTexture(asset); SetCamera(i); SetCameraDistance; SetCameraFacing; SetCameraPosition; SetCameraRoll; SetCameraTarget; SetCustomCamera(i); SetDesaturation; SetFacing; SetFogColor(r,g,b,a?); SetFogFar; SetFogNear (L518); SetGlow (L527); SetGradientMask; SetLight(enabled, ModelLight{omnidirectional, point, ambientIntensity, ambientColor, diffuseIntensity, diffuseColor}) (L548); SetModel(asset:ModelAsset, noMip=false) (L558); SetModelAlpha (L568); SetModelDrawLayer(layer) (L577); SetModelScale; SetParticlesEnabled(bool) (L595); SetPaused (L604); SetPitch; SetPosition; SetRoll; SetSequence(seq) (L642); SetSequenceTime(seq, timeOffset) (L651); SetShadowEffect (L661); SetTransform(translation?, rotation?, scale?) (L670); SetUseGBuffer(bool) [HasRestrictions] (L681); SetViewInsets(l,r,t,b); SetViewTranslation(x,y); TransformCameraSpaceToModelSpace(vec3)->vec3 (L713); UseModelCenterToTransform. CharacterModelBase (PlayerModel family): ApplySpellVisualKit(id, oneShot); CanSetUnit; FreezeAnimation(anim, variation, frame) (L29); GetDisplayInfo; GetDoBlend; GetKeepModelOnHide; HasAnimation; PlayAnimKit; RefreshCamera; RefreshUnit; SetAnimation(anim, variation?); SetBarberShopAlternateForm; SetCamDistanceScale; SetCreature(creatureID, displayID=0); SetDisplayInfo(displayID, mountDisplayID?); SetDoBlend; SetItem; SetItemAppearance; SetKeepModelOnHide; SetPortraitZoom; SetRotation(rad, animate=true); SetUnit(unit, blend=true); StopAnimKit; ZeroCachedCenterXY. CinematicModel: EquipItem; InitializeCamera; InitializePanCamera; RefreshCamera; SetAnimOffset; SetCameraPosition; SetCameraTarget; SetCreatureData; SetFacingLeft; SetFadeTimes; SetHeightFactor; SetJumpInfo; SetPanDistance; SetSpellVisualKit; SetTargetDistance; StartPan; StopPan; UnequipItems. DressUpModel: Dress, Undress, TryOn, transmog functions, SetSheathed, IsGeoReady, etc. ModelFFX: AddCharacterLight, AddLight, AddPetLight, ResetLights. (https://github.com/Gethe/wow-ui-source/blob/1463c686270b6c64e2c5c228f447c4597c0f8ba6/Interface/AddOns/Blizzard_APIDocumentationGenerated/SimpleModelAPIDocumentation.lua ; FrameAPICharacterModelBaseDocumentation.lua ; FrameAPICinematicModelDocumentation.lua ; FrameAPIDressUpModelDocumentation.lua ; SimpleModelFFXAPIDocumentation.lua)
- [verified] These APIs are identical in Classic Era 1.15.9, TBC Anniversary 2.5.6 and MoP Classic 5.5.4. Retail 12.1.0 differs only by actor SetModelByHyperlink and two front-end lobby functions. The older 2.5.5 build (68101) lacked actor SetPaused/GetPaused, SetGradientMaskWithDyes and Model:SetUseGBuffer.: I parsed the docs and diffed function signatures per file. Against classic_era and classic: identical for ModelScene, ActorBase, SimpleModel, OffScreenFrame, Frame and TextureBase. Against live: only ReleaseFrontEndCharacterDisplays, SetFrontEndLobbyModelFromDefaultCharacterDisplay and SetModelByHyperlink (actor), plus Texture radial-progress/SVG and Frame roleset/vector-graphics extras. Against 2.5.5 commit 1e059c80: missing actor GetPaused/SetPaused, DressPlayerSlot and transmog functions, SetGradientMaskWithDyes, SetUseGBuffer. (raw.githubusercontent.com/Gethe/wow-ui-source/{1463c686,1e059c80,classic_era,classic,live}/Interface/AddOns/Blizzard_APIDocumentationGenerated/*.lua)
- [verified] No documented function anywhere in the 2.5.6 API docs does per-actor clipping, stencil, depth writing or testing, raycast or mouse intersection, unproject, or exposes projection or view matrices. The only depth-related controls are scene-wide: near/far clip, Project3DPointTo2D (returns a 'depth'), fog near/far, view insets/translation (2D viewport) and the scene's draw layer.: I grepped every file in Blizzard_APIDocumentationGenerated for function names containing Depth|Clip|Stencil|Intersect|Raycast|Unproject|Project|Viewport|Matrix|Snapshot|FrameBuffer|Overlap|GBuffer|Occlu|WorldToScreen. The only hits: Get/SetCameraNearClip, Get/SetCameraFarClip, Get/SetAllowOverlappedModels, Project3DPointTo2D (ModelScene); DoesClipChildren/SetClipsChildren, IsFrameBuffer/SetIsFrameBuffer (Frame); SetUseGBuffer (Model); OffScreenFrame snapshot functions; ScriptRegion:Intersects (2D rect test). CalculateMouseIntersection does not exist. (Gethe/wow-ui-source@1463c686 Interface/AddOns/Blizzard_APIDocumentationGenerated/ (all files))
- [uncertain] ModelScene:SetAllowOverlappedModels(bool) exists in 2.5.6, but nothing documents what it does. Blizzard enables it on scenes that overlap other model scenes on screen (shop product cards, the full-screen scripted-effects scene), citing bug CLASS-44103. It is the most promising untested switch for the shared-depth behaviour the user observed (facts 4 and 5). The addon never calls it.: The doc has only the bool argument (FrameAPIModelSceneFrameDocumentation.lua L350). classic_anniversary Blizzard_SharedXML/ModelSceneMixin.lua L10-12: 'if self.allowOverlappedModels then self:SetAllowOverlappedModels(true)'. ScriptedAnimations/ScriptAnimatedModelScene.lua L24-26 comment: 'Automatically allow overlapped models for these types of scenes. Could be optimized to only enable when there are multiple models.' (so it has a cost). Blizzard_StoreUI/Classic/Blizzard_StoreUIInsecure.lua L24/L29 switch it on/off with the shop preview, comment 'CLASS-44103: Automatically allow overlapped models for shop scenes'. Retail ModelSceneMixin.xml L21 (StoreModelSceneMixinTemplate), Blizzard_CatalogShop.xml L133, Blizzard_CatalogShop_SharedProductCards.xml L43 set KeyValue allowOverlappedModels=true. warcraft.wiki.gg: added in 11.2.5, no explanation. Grep of addon\DisasterZone (Render3D, UI/StrategyMap3D.lua, Games/Trainer): no call. My guess at what it does: with the default (false), scenes share one uncleared depth buffer (matches fact 4); with true, each scene gets its own or a cleared depth buffer and composites in UI order. Not tested. (https://github.com/Gethe/wow-ui-source/blob/1463c686270b6c64e2c5c228f447c4597c0f8ba6/Interface/AddOns/Blizzard_SharedXML/ScriptedAnimations/ScriptAnimatedModelScene.lua#L24-L26 ; .../Blizzard_StoreUI/Classic/Blizzard_StoreUIInsecure.lua#L24 ; live .../Blizzard_SharedXML/ModelSceneMixin.xml#L21)
- [verified] ModelScene:SetDrawLayer(layer) and Model:SetModelDrawLayer(layer) put the 3D models on a draw layer (BACKGROUND/BORDER/ARTWORK/OVERLAY/HIGHLIGHT, default ARTWORK) inside the scene's own frame. Textures created on the scene frame itself can therefore sit under or over the models without separate frame levels. This orders by layer, not by depth.: FrameAPIModelSceneFrameDocumentation.lua L435 SetDrawLayer(layer:DrawLayer); GetDrawLayer->layer,sublevel. SimpleModelAPIDocumentation.lua L577 SetModelDrawLayer. UI.xsd L1374 ModelScene attribute drawLayer default ARTWORK; L1010 Model drawLayer default ARTWORK; L33-41 DRAWLAYER enum. Retail Blizzard_CatalogShop.xml uses <ModelScene ... drawLayer="BORDER">. (Gethe/wow-ui-source@1463c686 Blizzard_APIDocumentationGenerated/FrameAPIModelSceneFrameDocumentation.lua L435 ; Blizzard_SharedXML/UI.xsd L1354-1378)
- [likely] Model loading: actors load M2 models by file ID or path (SetModelByFileID / SetModelByPath, with an optional useMips flag); Model frames use SetModel(ModelAsset). Room doodads (M2 props) can therefore be real actors in the boss scene: correct per-pixel occlusion with bosses, and the missing props come back. Loading a WMO room file into an actor is most likely unsupported.: ActorBase docs L405/L420. Blizzard uses actor:SetModelByFileID for spell-effect M2s (ScriptAnimatedModelSceneActor.lua L67), CommentatorVictoryFanfare.lua L13 and housing decor (Blizzard_HousingModelPreview.lua L185-186, after SetPreferModelCollisionBounds(true)). HousingCatalogUIDocumentation.lua L523: field asset:ModelAsset documented as '3D model asset for displaying in the UI; May be nil if the entry doesn't have a model, or has one that isn't supported by UI model scenes' (next to isPrefab, L540). That strongly suggests some world assets, likely WMO prefabs, cannot be shown in ModelScenes. The login-screen background is one large M2 scene (GlueParent.lua L446-447: model:SetModel(background, true); model:SetUseGBuffer(true)), so a full environment can be an M2. Custom M2 files loaded from an addon folder: no working report found (wowinterface thread t=57884 failed). gen_rooms.py already resolves WMO and ADT fdids via wago (fdid_of, casc). (Gethe/wow-ui-source@1463c686 Blizzard_APIDocumentationGenerated/HousingCatalogUIDocumentation.lua L523 ; Blizzard_HousingModelPreview/Blizzard_HousingModelPreview.lua L185-186 ; https://www.wowinterface.com/forums/showthread.php?t=57884)
- [verified] Animation control: actors have no set-animation-time function. A pose is frozen with SetAnimation(anim, variation, animSpeed=0, animOffsetSeconds=t), which is what Blizzard does. There are also actor SetPaused (new in 2.5.6), scene SetPaused, PlayAnimationKit/StopAnimationKit and SetAnimationBlendOperation. Model frames add SetSequence, SetSequenceTime(seq, offset), AdvanceTime and SetPaused; PlayerModel adds FreezeAnimation(anim, variation, frame).: ActorBase L337 SetAnimation(animation, variation?, animSpeed=1, animOffsetSeconds=0). Blizzard_SharedXML/ModelSceneMixin.lua L471/L483: actor:SetAnimation(0, 0, 0, 0) (frozen) and L474/L478 actor:SetAnimation(0, 0, actorInfo.speed, 0). ScriptAnimatedModelSceneActor.lua L84: SetAnimation(anim, 0, animationSpeed, animationStartOffset). Actor L261 SetPaused(paused, affectsGlobalPause=true), absent in 2.5.5 docs. SimpleModel L642/L651; CharacterModelBase L29 FreezeAnimation(anim, variation, frame). So SetAnimation(0,0,0,0) should match the frame-0 standing pose that m2_tools.standing_vertices uses for occluder boxes; worth checking in game. (Gethe/wow-ui-source@1463c686 Interface/AddOns/Blizzard_SharedXML/ModelSceneMixin.lua L471-483 ; FrameAPIModelSceneFrameActorBaseDocumentation.lua L337)
- [verified] Particles: on ModelScene actors the only control is SetParticleOverrideScale(scale?) (nil resets). Model, PlayerModel and CinematicModel frames have SetParticlesEnabled(bool). There is also actor SetSpellVisualKit(id, oneShot) and PlayerModel ApplySpellVisualKit.: ActorBase L456 SetParticleOverrideScale(scale:number? nilable); GetParticleOverrideScale->number?. SimpleModelAPIDocumentation.lua L595 SetParticlesEnabled(enabled). ScriptedAnimationEffect structure carries particleOverrideScale (ScriptedAnimationsDocumentation.lua). (Gethe/wow-ui-source@1463c686 FrameAPIModelSceneFrameActorBaseDocumentation.lua L456 ; SimpleModelAPIDocumentation.lua L595)
- [verified] Textures have nothing depth-related. TextureBase only offers 2D tools: SetVertexOffset, SetTexCoord, masks (static image alpha), blend modes, desaturation, rotation, gradients. Region:SetDrawLayer(layer, sublevel) orders within a frame. Frame:SetDepth (stereoscopic 3D, added 3.0.8) is not in the 2.5.6 docs.: SimpleTextureBaseAPIDocumentation.lua: ClearVertexOffsets, SetVertexOffset (L465), SetBlendMode (L286), SetMask (L354), SetTexCoord, SetRotation, SetGradient, SetDesaturation, SetSnapToPixelGrid, SetTexelSnappingBias, slice functions; SimpleTextureAPIDocumentation.lua AddMaskTexture (L10)/RemoveMaskTexture; SimpleRegionAPIDocumentation.lua SetDrawLayer(layer, sublevel=0), SetVertexColor, SetAlpha. No Depth/Z function in any Texture, Region or Frame doc. warcraft.wiki.gg API_Frame_SetDepth: 'Sets the stereoscopic (3D) depth', Patch 3.0.8 added. UI.xsd still has a frame attribute depth (L739 area). SetDepth on a frame does not write the depth buffer that models use. (Gethe/wow-ui-source@1463c686 SimpleTextureBaseAPIDocumentation.lua, SimpleTextureAPIDocumentation.lua, SimpleRegionAPIDocumentation.lua ; https://warcraft.wiki.gg/wiki/API_Frame_SetDepth)
- [uncertain] Frame:SetIsFrameBuffer(bool) and SetFlattensRenderLayers(bool) exist in 2.5.6 (in Classic since 2.5.2). A frame-buffer frame is rendered into its own render target and then composited. Whether ModelScenes inside it get their own or a cleared depth buffer is unknown. If they do, wrapping each scene in its own frame-buffer frame would isolate scene depth the way SetAllowOverlappedModels might.: SimpleFrameAPIDocumentation.lua L1215 SetIsFrameBuffer, L1106 SetFlattensRenderLayers, L1058 SetClipsChildren, L1005 SetAlphaGradient. warcraft.wiki.gg: 'Controls whether or not a frame is rendered to its own framebuffer prior to being composited atop the UI'; added 9.1.0, Classic 2.5.2, renamed 10.0.0; notes it needs flattened render layers. Blizzard uses frameBuffer="true" on WorldMapFrame (Blizzard_WorldMap.xml L29) and on CharacterVASTemplate. (https://warcraft.wiki.gg/wiki/API_Frame_SetIsFrameBuffer ; Gethe/wow-ui-source@1463c686 Blizzard_APIDocumentationGenerated/SimpleFrameAPIDocumentation.lua L1215)
- [uncertain] OffScreenFrame (render a frame to a texture) is documented in 2.5.6. If addons can create it, model scenes (e.g. clipped depth slices) could be captured into ordinary textures and layered with the room by frame level, which avoids the shared depth buffer. Nothing in Blizzard's code uses it, and whether CreateFrame accepts it is unknown.: SimpleOffScreenFrameAPIDocumentation.lua: ApplySnapshot(texture:SimpleTexture, snapshotID)->success (L10); Flush(); GetMaxSnapshots(); IsSnapshotValid(id); SetMaxSnapshots(n); TakeSnapshot()->snapshotID? (L69); TestPrintToFile(id, filename) 'Unavailable in public builds' (L82); UsesNPOT()->bool?. UI.xsd L1615: <xs:element name="OffScreenFrame" type="FrameType">. Grep of all classic_anniversary Lua/XML: no use. Wiki UIOBJECT_OffScreenFrame: 'allows for a frame to be rendered to a predefined texture' (stub, 2015). The current warcraft.wiki.gg CreateFrame type list omits OffScreenFrame (it lists UiCamera); old Wowpedia listed it. Snapshots can't be read back into Lua. (Gethe/wow-ui-source@1463c686 Blizzard_APIDocumentationGenerated/SimpleOffScreenFrameAPIDocumentation.lua ; Blizzard_SharedXML/UI.xsd L1615 ; https://warcraft.wiki.gg/wiki/UIOBJECT_OffScreenFrame ; https://warcraft.wiki.gg/wiki/API_CreateFrame)
- [verified] The schema defines other model-type frames with no Lua docs: MapScene (a ModelType, use unknown) and UiCamera (ModelType; the wiki lists it as a CreateFrame type). Model:SetUseGBuffer is restricted (HasRestrictions) and only used by the login screen.: UI.xsd L1014-1016: Model, ModelFFX, MapScene elements of type ModelType. L1307-1312: UiCameraType extends ModelType. No Blizzard Lua or XML uses MapScene or UiCamera. SimpleModelAPIDocumentation.lua L681 SetUseGBuffer HasRestrictions=true; GlueParent.lua L447 model:SetUseGBuffer(true) for the login background. (Gethe/wow-ui-source@1463c686 Interface/AddOns/Blizzard_SharedXML/UI.xsd L1014-1016, L1307-1312)
- [verified] Bounding-box, lighting, fog and alpha tools that matter for fitting and appearance. Actor: GetActiveBoundingBox, GetMaxBoundingBox, SetPreferModelCollisionBounds, SetUseCenterForOrigin/IsUsingCenterForOrigin, IsLoaded, IsGeoReady. Scene: light type (Directional or Point), position, direction, ambient and diffuse color, SetLightVisible. Fog: near, far, color. Desaturation on scene and actor. Alpha: actor SetAlpha, Hide, Show, SetShown. Nothing documents whether an actor below alpha 1 still writes depth.: ActorBase L18/L97/L504/L551/L251; Actor L178 IsGeoReady; ModelScene L444-464 fog, L517-526 light type/visible; FrameAPIModelSceneFrameSharedDocumentation.lua ModelLightType {Directional=0, Point=1}; XSD ModelScene fogNear default 0, fogFar default 1.0 (L1372-1373); actor XML attributes file, fileID, alpha, scale, desaturation (UI.xsd L1117-1142). (Gethe/wow-ui-source@1463c686 FrameAPIModelSceneFrameActorBaseDocumentation.lua ; FrameAPIModelSceneFrameDocumentation.lua ; UI.xsd L1117-1142)
- [uncertain] An exact per-pixel method that needs no new API, based on the user's own facts 4-6 (scenes share one depth buffer when they use the same near/far clip). Draw 'proxy' models that match the room geometry in a scene at the lowest frame level. The room textures paint over them, and the boss and player scenes sit above the room with the same clip range. Boss pixels behind a proxy then fail the depth test and the room shows instead; boss pixels in front draw over the room. This only works if the depth buffer survives the UI textures drawn in between, and it needs an opaque primitive model. Doodads need no proxy: they are themselves real M2 actors.: Facts 4-6 plus current practice: the boss scene already draws over room textures and the 'copies' above it hide it, so UI draw order is respected and textures don't block model depth. Candidate primitives in wago's listfile (not checked against the 2.5.6 client): spells/unitcube.m2 fdid 167145, spells/errorcube.m2 fdid 166046, world/expansion06/.../500x500_invisibleplane.m2 fdid 1414903 (Legion, probably absent; might not write depth). Constraints: actors scale uniformly only (fact 7) but can yaw, pitch and roll. A cube's side faces show past a wall's edge at openings, so cubes must stay inside solid volume or behind other room surfaces. The generator would tile coplanar regions offline. Proxy accuracy decides correctness; the depth test itself is exact per pixel. (https://wago.tools/files?search=cube.m2 ; in-game facts 4-6 from the task; C:\Users\emilo\CDLoot-dev\addon\DisasterZone\Render3D\View.lua L64-90 (current scene setup))
- [verified] The addon's current code never uses SetAllowOverlappedModels, SetIsFrameBuffer, OffScreenFrame, SetDrawLayer on scenes, or SetModelByFileID for room doodads. To hide the slicing scenes it uses alpha 0 plus an empty clip range.: Grep of C:\Users\emilo\CDLoot-dev\addon\DisasterZone (Render3D/**, UI/StrategyMap3D.lua, Games/Trainer/**): only SetCameraNearClip calls (View.lua L82, L335-338, L389; StrategyMap3D.lua L1495, L1566, L1666-1668) and texture SetDrawLayer calls in Room.lua. View.lua L330-341 hides slice scenes with SetAlpha(0) + near 0.01 / far 0.011. (C:\Users\emilo\CDLoot-dev\addon\DisasterZone\Render3D\View.lua L330-341)

Open questions:
- What SetAllowOverlappedModels(true) does in game. Test: repeat the fact-4 setup (player 15 yd, Brutallus 35 yd, two scenes, same 0.5/500 clips) with true on both scenes, then on only one. If the frame level now decides who is on top, each scene has its own or a cleared depth buffer. Depth slicing (fact 5) would then work, and the 'proxy' method would not work on scenes set to true.
- Do ModelScenes inside a frame with SetIsFrameBuffer(true) (plus SetFlattensRenderLayers(true)) get isolated depth? Test: put each scene of the fact-4 test in its own frame-buffer frame.
- Can the addon create an OffScreenFrame in 2.5.6? Test with pcall(CreateFrame, 'OffScreenFrame', nil, UIParent). If it works, do TakeSnapshot() and ApplySnapshot(tex, id) capture a child ModelScene (with alpha), how many snapshots per frame are allowed, and what does it cost?
- Does the shared depth buffer survive UI textures drawn between scenes, so the 'proxy' method works? Test: scene A (low frame level) with an opaque model in front of a boss, a full-screen texture at a middle level covering A, scene B (top level, same clips) with the boss. Is the boss hidden exactly where A's model is in front? Also check whether a scene at SetAlpha(0), or an actor at alpha 0 or 0.01, still writes depth (an invisible proxy would make covering it with room textures unnecessary).
- Does actor:SetModelByFileID(<WMO root fdid>) or a WMO group fdid return success and draw anything? Housing docs suggest not. Does SetModelByFileID(<room doodad M2 fdid>) place the doodad correctly with DisasterZone's position, scale and yaw conventions (doodad scale is uniform, which fits)?
- Do spells/unitcube.m2 (167145) and spells/errorcube.m2 (166046) exist in the 2.5.6 anniversary CASC? What are their exact size, pivot and material (opaque, depth-writing, unlit)? Check with dev/generators casc()/m2_tools.
- Does actor SetAnimation(0, 0, 0, 0) reproduce exactly the frame-0 Stand pose that m2_tools.standing_vertices uses for occluder boxes?
- What scale does Project3DPointTo2D's 'depth' use (linear yards or normalized, reversed-Z or not)? Calling it with points at known distances under different near/far settings would confirm the fact-5 explanation (depth normalized per scene).
- The docs may not list every method. To be sure nothing else exists, dump the real method tables in game: for k in pairs(getmetatable(scene).__index), the same for an actor (scene:CreateActor()), and for CreateFrame('PlayerModel') and CreateFrame('UiCamera').

### Short answer: everything needed for geometric occlusion can be produced offline, exactly as the clie

Short answer: everything needed for geometric occlusion can be produced offline, exactly as the client has it. I wrote a small read-only reader for the user's own install (C:\World of Warcraft\Data, build 2.5.6.69795), so nothing was downloaded. With it I read all 141 creature displays on the board. Every one has all of its animations inside the .m2 file (no separate .anim files) and a single LOD skin. The triangles come from the .skin files, which m2_tools.py does not read yet.

I wrote a full animator (all bone tracks plus global sequences). Over the whole Stand animation, its union box matches the client's own Stand box (GeoBox) within 0.15 model units for the Lurker. For Kil'jaeden it matches only once transparent effect triangles are left out. For Brutallus and Magtheridon the client's box is larger than the mesh, so they are not a check.

Measured in the shipped rooms (simulated renders with the real meshes): today's copies rule gets 10.35% of Brutallus' pixels wrong, 3.0-3.5% of the Lurker's and 0.07% of Magtheridon's.
- Almost all of it is the boss being hidden where he should show. The part-boxes' copies are a union, so at each pixel the farthest box plane decides.
- Brutallus' errors are ground 0.2-1.9 yd high, behind his legs.

With the real pose:
- Per-bone convex hulls bring the error down to 0.05-0.28%.
- Clipping with the true mesh itself is exact by definition.
- The copy textures that exact clipping needs are measured: median 7-12 per view for Brutallus and Magtheridon, 269 for the Lurker, max 643. That fits today's budget of 1500 copy textures.

The expensive part is not the textures but working out, in Lua, which part of the boss is visible at each point of the screen (hidden-surface work on 1,700-6,000 triangles) every time the camera moves.

Animation is the other limit. The board calls SetAnimation(0) with no time set, and no API returns an actor's animation time. The 2.5.6 API does let the addon set the time and speed and pause an actor, so a frozen pose at a known time is possible (not yet tested in game). Without that, being one 60-fps frame out of step already gives 1.2% wrong pixels on the Lurker, and 16% at a random point in his animation.

Data problems in the current pipeline:
- The dev kit's downloads are not tied to a build. 257 of 481 cached files differ from the installed client. 101 of 290 WMO room-geometry files differ, and the downloaded copies have about 9% fewer drawn triangles overall.
- Kil'jaeden's degenerate part boxes come from transparent effect triangles (3,956 of his 8,893), not from a wrong pose.
- 41 of the 141 board creatures use player-character models with gear. Their boxes are built from every hair and gear variant at once.

- [verified] Exact client model data is available offline from the user's own install. A minimal reader for the local game storage (CASC) reads any file by its file ID. All 141 creature displays the board uses are readable. Every animation is stored inside the .m2 (0 separate .anim files), and every model has exactly 1 skin LOD, so the client never swaps in a different mesh.: Installed build: .build.info lists wow_anniversary 2.5.6.69795 (build key 6761dba8...). The reader parses the build config, the .idx indices, BLTE, the encoding table and the root table. Survey of every display in parts.json: 141 read, 0 unreadable; LOD0 triangles median 1,950, p90 6,233, max 8,893, total 398,037; 317,513 vertices; 0 external sequences; 0 models with an AFID chunk; 0 with more than one skin. (scratchpad casc_local.py and m2_analyze.py (C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\aa52e4d4-c087-4769-a09e-98ce81f5d755\scratchpad\); C:\World of Warcraft\.build.info)
- [verified] Exact sizes of the four named boss models (local 2.5.6 files, LOD0 skin).: Brutallus (display 22711, file 123133, scale 6): 3,841 triangles, 3,438 vertices, 107 bones, 34 sequences, 20 particle emitters; 3,817 opaque + 24 alpha-key triangles.
Lurker (20216, file 124727, scale 2): 2,086 triangles (all two-sided), 1,726 vertices, 85 bones, 17 sequences, including 201/202 (Submerge/Submerged per wowdev) and 124-127.
Magtheridon (18527, file 125426, scale 4): 3,407 triangles, 2,779 vertices, 231 bones, 27 sequences.
Kil'jaeden (23200, file 124682, scale 6): 8,893 triangles, of which only 4,937 are opaque or alpha-key; 3,956 are alpha or additive with no depth write. 159 bones, 22 global sequences, 34 particle emitters.
All Stand animations have one variation (no 0.1); Stand lasts 4,000 / 2,000 / 4,000 / 2,000 ms. (m2_analyze.py and the material/batch parse (M2 materials at header 0x70, skin batches))
- [verified] A full skinning evaluator (every sequence, every time, global sequences) reproduces the client's Stand bounds. Every frame of stand, combat stand (25/26/27), run, swim, emerge and so on can be produced. Global sequences move no mesh vertices on these four bosses (they drive effects only).: Lurker: union over the Stand cycle [-9.71,-10.62,-20.51,5.68,10.58,8.39] vs Stand sequence bounds = GeoBox [-9.68,-10.55,-20.37,5.6,10.45,8.37].
Kil'jaeden, opaque triangles only: [-2.39,-2.15,-3.09,15.83,2.47,4.56], inside GeoBox [-5.96,-5.75,-3.23,15.65,2.84,4.88].
Brutallus' GeoBox is larger than his mesh; Magtheridon's equals the 85-unit header box, so neither is a usable check.
Vertices moved by global-sequence bones: 0 for all four.
Movement within one cycle, from Stand frame 0: Lurker Stand up to 26.96 yd (worst-frame p95 12.25 yd); Brutallus Stand up to 24.4 yd (p95 2.1 yd); combat stances and attacks 11-67 yd.
Limit: hermite and bezier keys are interpolated linearly here. (scratchpad m2_anim.py, boss_study.py)
- [verified] Player races are available as the classic models only (the HD _hd.m2 files are not in the 2.5.6 build). Their visible mesh depends on gear and appearance, which the board cannot get offline.: humanmale (file 119940): 4,229 triangles over all 49 submeshes, 121 bones, 148 sequences, all inline. orcmale (121287): 3,729 triangles, 138 sequences. humanmale_hd (1011653) and the other _hd files are not in the local root table.
The board uses SetModelByUnit for group members (StrategyMap3D.lua:2425), so geosets and attached item models come from the real gear.
41 of the 141 board creature displays have an ExtendedDisplayInfoID (character model plus gear), e.g. 18239/19048/20237 use bloodelffemale 116921 at 8,160 triangles. Their current boxes take all geosets (every hairstyle and gear variant). (m2_analyze.py on files 119940, 121287; CreatureDisplayInfo.csv)
- [verified] The current dev kit only extracts Stand frame-0 vertex positions. It reads no triangles, skins, materials or other frames, and it deletes the .m2 after use.: m2_tools.py:59-120 skins only sequence id 0 at its first key. It never reads the track's global-sequence field. It returns vertices plus the header box: no .skin, no submeshes or geosets, no material blend modes.
gen_rooms.py display_parts 1148-1194 turns them into at most 6 k-means boxes (split_parts 1197-1229) and deletes the downloaded .m2 (1186-1191). Only parts.json keeps the boxes.
wmo_tools.read_root only counts doodads (line 22). Nothing parses MODD/MODS/MODN or ADT MDDF, so M2 props are missing from rooms. (C:\Users\emilo\CDLoot-dev\dev\generators\m2_tools.py:59-120; gen_rooms.py:1148-1229; wmo_tools.py:17-42)
- [verified] Kil'jaeden's degenerate parts (single-point boxes) come from transparent effect geometry (alpha/additive, no depth write), not from a wrong pose. Part boxes and hulls should use only opaque and alpha-key triangles.: parts.json[23200] holds point boxes such as [-14.43,15.42,0.06,...]. The full-mesh Stand box reaches y ±15.4 and z 16.9. Opaque triangles only give a box inside GeoBox (see above).
StrategyMap3D.lua:722-731 already throws such parts away when they reach outside the client's box. (scratchpad material parse; UI\StrategyMap3D.lua:722-731)
- [verified] The dev kit downloads game files from wago.tools without pinning a build, and many differ from the installed client. That includes room geometry: some downloaded WMO groups have far fewer triangles than the client's own.: gen_rooms.py:115-121 and gen_trainer_heights.py:90 use https://wago.tools/api/casc/<fid>?download with no build.
Of 481 cached files, 222 are identical to the local client's, 257 differ and 2 are missing locally.
WMO groups: 101 of 290 differ; render triangles wago 1,147,215 vs local 1,256,477. Example: 108742.wmo has 1,844 triangles from wago vs 3,316 locally.
Cached model 191671.m2: 58 bones / 1,632 vertices vs 50 / 1,152 locally.
For the four bosses, frame 0 is the same either way (identical error results from both box sets). (comparison script over C:\Users\emilo\CDLoot-dev\dev\art\wmo and art\rooms vs casc_local.read_fid)
- [verified] Mechanism of today's copies rule (Q2):
(a) Each part box gets one upright plane through its axis, facing the camera. Room pieces on the camera side of that plane are copied, cut to the box's projected rectangle.
(b) Parts send o.w = 0, so their restricting regions are 0.5 px strips. Copies of overlapping parts of one model therefore add up as a union: at each pixel the threshold is the farthest plane among the boxes covering it.
(c) A floor cut keeps only room above the part's lowest point + 0.1 yd while the camera is above it.
(d) Boxes come from Stand frame 0 and never follow the animation.
(e) Hard caps: 19 occluder slots, 128 room pieces per slot, 1,500 copy textures in total; the farthest are dropped first.: Derive family A plane: Room.lua:1967-1986. Floor cut OZT: 1960-1965. Restricting region from o.w: 2005-2015. Group skip in Restrict: 2347-2350. Caps: 1833 and EmitSlot 2793-2829.
Parts set o.w = 0 and o.rb = half-diagonal: StrategyMap3D.lua:762. Part bottoms between -1.5 and 0.05 are clamped to 0.05: 759-760. (Render3D\Room.lua:1830-2104, 2188-2353, 2793-2829; UI\StrategyMap3D.lua:658-800)
- [likely] Measured accuracy of today's rule in the shipped rooms. It is mostly wrong hiding (room drawn over parts of the boss that are in front of it), caused by the far planes of the box union and by ground just above the floor cut.: Setup: per room, 32 views (distance 35/70 yd, pitch 25/45°, 8 directions) × 2 poses, 480×360, field of view 1.1; true skinned mesh; room z-buffer of front faces from the decoded room file.
Share of model pixels decided wrongly:
- Brutallus: today 10.35% (all of it hidden wrongly); one hull 0.18%; per-bone hulls 0.10%.
- Lurker: today 3.02% (frame 0) / 3.50% (later frame); one hull 1.5-2.0%; per-bone hulls 0.22-0.28%.
- Magtheridon: today 0.07%; per-bone hulls 0.05%.
The hull rows use hulls built for the true pose at each time.
Brutallus' wrongly hidden pixels show room surface at heights 0.2 / 0.47 / 0.85 / 1.32 / 1.92 yd (5th/25th/50th/75th/95th percentile): ground behind his legs.
Without a room, the gap between threshold and true surface for today's boxes is p50 9-15 yd and p95 21-34 yd (Kil'jaeden p50 54-59 yd). (scratchpad room_study.py (rs_*.txt), boss_study.py (bs_rest.txt))
- [likely] Q3: copies can be made per-pixel exact against the true surface. For each room triangle R, copy R minus the region where the model is nearer than R. Inside the area of one visible model triangle (or one hull face), 1/depth of both surfaces is linear in screen x and y, so 'room in front' is one half-plane cut. Every piece is copied on pixels the model does not cover (no threshold there), so each pixel still gets one consistent threshold and the result stays correct.: At a pixel without the model, copying all room pieces reproduces the room. On model pixels the threshold is the model's depth. Either way each pixel's copies are the nearest-first prefix the existing code already relies on (Room.lua:1822-1825).
Measured exact pieces, (room triangle, visible model triangle) pairs with the room in front, 900×600 views at 25/45 yd: Brutallus median 7 (max 39), Magtheridon median 12 (max 25), Lurker median 269 (max 643). Visible model triangles per view: 165-1,225.
These pixel-sampled counts are a lower bound; each piece is 1-2 textures, which still fits within COPY_TEX_MAX 1500. (scratchpad pairs_study.py (pr_*.txt))
- [uncertain] Q3 runtime cost: the bottleneck is Lua geometry, not textures.
- True mesh: each camera move needs the model's own hidden-surface result (or subtracting many convex areas) for 1,700-6,000 triangles. That is roughly 10-30+ ms in Lua for big models, unless limited to the few room triangles actually in front (median 2-11 per view, max 49).
- Per-bone hulls: 27-91 parts. Each hull's 'nearer than R' area is a single convex polygon: its outline cut by one half-plane per front face. So each R needs only a few convex subtractions.
- Hull sizes (unsimplified): one hull 98-112 faces; per-bone hulls 1,148 (Lurker) / 1,880 (Brutallus) / 2,906 (Magtheridon) faces; simplifying each hull to about 16 faces is needed.: Hull measurements: boss_study.py output (40 parts / 1,880 faces for Brutallus; 91 / 2,906 for Magtheridon; 27 / 1,148 for the Lurker).
The millisecond figures are estimates from operation counts (about 50-100 Lua operations per polygon clip), compared with the existing 7-12 ms per moving frame in the mock. They were not measured in Lua. (boss_study.py; Room.lua Clip/NearSide 2120-2208 as the cost model)
- [verified] Q4: the board plays Stand (id 0) on every boss with no variation, speed or offset. The player character uses 0/5/13/40/41/42. No API returns an actor's current animation time. The 2.5.6 API can set the time and speed and can pause, which allows a deterministic frozen frame.: a.anim = 0 on a model change: StrategyMap3D.lua:671. The model-loaded callback calls SetAnimation(actor.anim or default=0): View.lua:192-200. Walker table WANIM = {stand 0, run 5, back 13, fall 40, swimIdle 41, swim 42}: StrategyMap3D.lua:58, used at 2446-2451 and 2506-2511.
Classic_anniversary API docs:
- Actor base: SetAnimation(animation, variation?, animSpeed=1, animOffsetSeconds=0); GetAnimation; GetAnimationVariation; no getter for time.
- Actor: SetPaused(paused, affectsGlobalPause), GetPaused.
- ModelScene: SetPaused, SetAllowOverlappedModels. (https://raw.githubusercontent.com/Gethe/wow-ui-source/classic_anniversary/Interface/AddOns/Blizzard_APIDocumentationGenerated/FrameAPIModelSceneFrameActorBaseDocumentation.lua ; .../FrameAPIModelSceneFrameActorDocumentation.lua ; .../FrameAPIModelSceneFrameDocumentation.lua)
- [likely] The animation phase decides whether exactness holds on moving bosses. With a correct mesh but the wrong time, the Lurker is visibly wrong even one frame out of step. Brutallus is not affected.: Exact mesh at time t while the client shows t+lag, in the room. Lurker: 17 ms 1.19%, 33 ms 2.15%, 100 ms 5.47%, random phase (740 ms) 15.97% of model pixels wrong. Brutallus: 0.00-0.01%.
With no Stand variations the loop is deterministic, but it starts when the model loads, which the addon knows only to the nearest frame. (scratchpad pose_study.py (ps_*.txt))
- [verified] Error sources that remain even with exact model meshes. Particles cannot be handled by copies at all. Transparent parts lying in front of a wall that is itself in front of the opaque body cannot be drawn correctly by copies. Alpha-key cut-out cards follow their texture alpha, not their triangles.: Particle emitters per boss: Brutallus 20, Lurker 16, Magtheridon 14, Kil'jaeden 34.
Alpha-key triangles: Brutallus 24, Lurker 192, Magtheridon 24, Kil'jaeden 1,043.
Kil'jaeden's no-depth-write alpha/additive triangles: 3,956.
In-game fact 2: particles are not cut by a scene's clip planes. (material/batch parse in scratchpad)
- [likely] Offline data for more complete rooms is available from the same local storage: every WMO group as the client ships it, liquids, and M2 doodads with their placements. The doodads could even go into the ModelScene, where the GPU sorts them against the bosses exactly. Today's limits are the generator (no doodads, ADT liquids not done) and the renderer budget.: MAX_TRIS 7000 / MAX_NODES 2990 at gen_rooms.py:59-60. WMO roots expose MODD/MODS/MODN and ADT obj0 files hold MDDF; neither is parsed today.
Doodad M2s can be skinned at Stand t=0 by the same m2_anim.py. Shipping full meshes for all 141 creatures (398k triangles) is too big; per-encounter, simplified or hull data is needed. (gen_rooms.py:59-60; wmo_tools.py:17-42; m2_anim.py)

Open questions:
- Does SetAnimation(0, nil, 0, t) (speed 0) or actor:SetPaused(true[, true]) freeze the pose on the 2.5.6 client at exactly the frame the offline evaluator computes? This needs an in-game test. The evaluator also interpolates hermite/bezier keys linearly.
- GPU option not covered by the Lua research: with the shared depth buffer (fact 4), a scene of depth-only room stand-in models (below the room textures, same clip range) could hide models per pixel with no copies. That needs: (a) the depth buffer to survive UI textures drawn between two scenes, (b) an M2 primitive that can form room triangles (actors scale uniformly only), (c) knowing what SetAllowOverlappedModels does. All three are unverified.
- Lua cost of hidden-surface removal (or subtracting convex areas) for 1,700-6,000-triangle models when the camera moves, in the real client. My 10-30+ ms figure is an estimate, not a measurement.
- Should rooms and creature data be rebuilt from the installed client files instead of unpinned wago downloads? 101 of 290 WMO groups differ, with about 9% fewer triangles in the downloaded copies.
- 41 of the 141 board creatures use player-character models with gear. Exact meshes need the gear and hair data (CreatureDisplayInfoExtra, NPCModelItemSlotDisplayInfo, ItemDisplayInfo geoset groups, attached item M2s). The player's own walker depends on live gear and needs a proxy or margin.
- The Lurker's offset from his circle (noted in memory) and how exactly models are placed (DISPLAY_CENTRE). Any placement error adds straight to the occlusion error; the study assumed exact placement.
- My stand-in for today's rule leaves out family B and skip, the slot and texture caps, the near plane, and other models' restricting regions. The in-room percentages show what kind of errors happen and roughly how many; they are not an exact replay of the client.

### Nobody has publicly shown a custom 

Nobody has publicly shown a custom .m2 loading from an addon folder on any CASC client (Retail 7.x+, Classic Era 1.13+, TBC Classic/Anniversary 2.5.x). Nobody has publicly shown that it fails on these clients either. The only failure report is a 2020 WoWInterface thread about a WotLK private-server client: the path had no file extension and the thread was closed before anyone answered. The old wiki text that says it is 'theoretically possible' dates from the MPQ era.

What the evidence does settle on 2.5.x:
(1) Loading models by path is supported. Model:SetModel(asset) and ModelSceneActor:SetModelByPath(asset[, useMips]) return success, and the actor also has IsLoaded, GetModelFileID and GetModelPath. Source: the 2.5.x API docs and usage strings in the installed exe.
(2) Since 8.2 the client accepts file paths only under Interface\ (plus Fonts\ for SetFont), so Interface\AddOns\... is inside the allowed namespace.
(3) Loose files get temporary negative FileDataIDs. The client builds this list from the whole game folder and does not filter by extension: .txt, .jpg, .json and .slug files all get IDs. So an .m2 or .skin placed in the addon folder will almost certainly get an ID too. 2.5.x ships C_UIFileAsset.GetFileID, IsKnownFile and IsLooseFile, which can confirm this. Since 9.0.1, new files need only a /reload.
(4) Textures load from the addon folder by path: confirmed locally, since the addon already ships and uses 66 .blp and 11 .tga files.
(5) No API on 2.5.x replaces a model's texture, except Model:ReplaceIconTexture. That only fills the item-icon texture slot (type 14) and exists only on the old Model widget, not on ModelSceneActor.
(6) No UI model API can load a WMO.
(7) Blizzard's own M2 files load by FileDataID: doodads, GameObject models and spell effects. This already works in game in the Trainer, so the missing props could be added natively as actors.

The real risk is not the .m2 file but its .skin file. Retail-format 2.5.6 M2 files (MD21, version 274) find their skin through the SFID chunk, which stores a FileDataID. I checked this on a cached 2.5.6 model. A loose skin only has a temporary negative ID that shifts whenever other files are added, so SFID cannot point at it reliably. Whether the 2.5.6 loader still falls back to finding skins by file name (legacy MD20 files, or MD21 files without an SFID chunk) is unknown. wowdev says 'If the first magic is MD20, it will be loaded just fine', and the exe contains both 'every m2 will scan the folder for skin profiles' and 'LoadSkinProfile failed because of no skin profile %s fileDataID %d', which hints that both lookup paths still exist.

Textures are not a blocker. A custom room M2 can point its TXID chunk at Blizzard's own WMO texture FileDataIDs, which are stable.

One in-game session settles it:
- Variant A: a byte copy of a small Blizzard M2 with its vertices scaled 3x, keeping its real SFID/TXID. This tests whether loose M2 files load at all.
- Variants B and C: the same model as a non-chunked MD20 file plus 'name00.skin', and as an MD21 file without an SFID chunk. These test whether custom skins, and therefore custom geometry, are possible.
For each variant, check C_UIFileAsset.IsLooseFile/GetFileID, the success value from SetModelByPath, IsLoaded, GetModelFileID and GetActiveBoundingBox, then read Logs\Model.log.

If A and B or C work, the room can be shipped as M2 actors in the same ModelScene as the creatures, using the same clip planes. Room-vs-model depth then becomes per-pixel exact on the GPU, with no face budget and with doodads included. If A fails while IsLooseFile is true, the loader rejects loose models and that approach is dead. In that case only Blizzard's M2 doodads can be added natively.

Note: the installed client is 2.5.6.69795 (wow_anniversary), not 2.5.5.

- [verified] No public, modern-client (CASC) proof exists either way that an addon can display a custom .m2 shipped in Interface\AddOns. The only concrete failure report is a 2020 WoWInterface thread: the user tried :SetModel("Interface\\AddOns\\MyAddon\\MyModel") on a WotLK private-server client, with no file extension, and the thread was closed without a technical answer. The 'theoretically possible, almost no addons do it' text on the SetModel wiki page dates from the MPQ era.: The WoWInterface thread t=57884 (March 2020) has only off-topic replies about private servers. The warcraft.wiki.gg API_Model_SetModel page still says meshes use '.mdx', are in model.MPQ, and that a mesh not shipped with the game 'you'll might be forced to call SetModel() at startup'. A Sourcegraph public code search found no Lua calling SetModel/SetModelByPath with an Interface/AddOns path and no repo with .m2 or .skin files under an AddOns path. SetModelByPath hits were only API annotation files: Ketho/vscode-wow-api, Questie .types, wowless, Gethe/wow-ui-source docs. The mmo-champion Classic thread says 'not possible with addons', but it is about replacing the game's models, not showing new ones. (https://www.wowinterface.com/forums/showthread.php?t=57884 ; https://warcraft.wiki.gg/wiki/API_Model_SetModel ; https://www.mmo-champion.com/threads/2448631-Classic-Addon-That-Changes-Models ; sourcegraph.com stream API queries (SetModelByPath; type:path \.m2$ with AddOns))
- [verified] On 2.5.x, models can be loaded by path. ModelSceneActor has SetModelByPath(asset: FileAsset, useMips=false) -> success:bool and SetModelByFileID(asset, useMips) -> success, plus IsLoaded, GetModelFileID and GetModelPath. The old Model widget has SetModel(asset: ModelAsset, noMip) and GetModelFileID.: In the classic_anniversary branch API docs, FrameAPIModelSceneFrameActorBaseDocumentation.lua has SetModelByFileID at line 405 and SetModelByPath at line 420, and SimpleModelAPIDocumentation.lua has SetModel at line 558. The installed exe contains 'Usage: local success = self:SetModelByPath(asset [, useMips])', 'Usage: local path = self:GetModelPath()' and 'Usage: self:SetModel(asset [, noMip])'. WeakAuras' 8.2 migration resolved model paths to IDs with SetModel(path) followed by GetModelFileID() (PR 1293 diff). (https://github.com/Gethe/wow-ui-source/blob/classic_anniversary/Interface/AddOns/Blizzard_APIDocumentationGenerated/FrameAPIModelSceneFrameActorBaseDocumentation.lua (local copy C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\aa52e4d4-c087-4769-a09e-98ce81f5d755\scratchpad\docs\) ; C:\World of Warcraft\_anniversary_\WowClassic.exe strings ; https://github.com/WeakAuras/WeakAuras2/pull/1293)
- [verified] Since 8.2, files can be addressed by path only under Interface\ (plus Fonts\ for SetFont). An addon path like Interface\AddOns\X\room.m2 is inside that allowed namespace; a custom model elsewhere, such as Creature\..., would not be.: Patch 8.2.0 API changes: 'No files outside of Interface\ can be addressed by file path anymore'; 'GetFileIDFromPath() will no longer work for non-interface file paths'; 'Paths to Fonts\ are still accessible for FontInstance:SetFont()'; sounds can no longer be replaced by dropping files into Sound\. (https://warcraft.wiki.gg/wiki/Patch_8.2.0/API_changes ; https://warcraft.wiki.gg/wiki/FileDataID)
- [likely] The client gives every loose file a temporary negative FileDataID from an in-memory listing it builds at startup. The listing covers the game folder and does not filter by extension, so an .m2 or .skin in the addon folder will very likely be indexed too. Since 9.0.1 the folder is rescanned on /reload, so new files need no restart on Windows. The negative IDs change whenever other files are added or removed.: GetFileIDFromPath docs: 'Negative integers are temporary IDs; these are not specified in the CASC root file and may change when the client is restarted', with the example GetFileIDFromPath("Interface/testimg.jpg") -- -1163. WoWUIBugs #287: .slug/.slugo files 'aren't ignored when populating the in-memory file listing', and Errors\*.txt and Cache/Avatar/Group .jpg/.json files also shift local IDs. A Gnomesweeper PR measured IDs -2411..-2436 for addon textures. Patch 9.0.1: 'New files and TOC format metadata changes no longer require a client restart to take effect, only a /reload (on Windows).' (https://warcraft.wiki.gg/wiki/API_GetFileIDFromPath ; https://github.com/Stanzilla/WoWUIBugs/issues/287 ; https://github.com/Spotnick2/Gnomesweeper/pull/33 ; https://warcraft.wiki.gg/wiki/Patch_9.0.1/API_changes)
- [verified] 2.5.x ships C_UIFileAsset.GetFileID(asset), IsKnownFile(asset) and IsLooseFile(asset). These can show in game whether a shipped .m2 or .skin is indexed as a loose file and what temporary ID it got. They were added in retail 12.0.7 but are present in the Anniversary client.: UIFileAssetAPIDocumentation.lua in the classic_anniversary branch (Environment 'All') says IsLooseFile is 'True if the asset refers to a loose file known to the client' and that IsKnownFile does not verify that a loose file exists or opens. The exe contains 'Usage: local isLooseFile = C_UIFileAsset.IsLooseFile(asset)' and 'Usage: local assetFileID = C_UIFileAsset.GetFileID(asset)'. Total RP 3 PR #1396 says these are 'supported on all clients'. (https://github.com/Gethe/wow-ui-source/blob/classic_anniversary/Interface/AddOns/Blizzard_APIDocumentationGenerated/UIFileAssetAPIDocumentation.lua ; https://warcraft.wiki.gg/wiki/Patch_12.0.7/API_changes ; https://github.com/Total-RP/Total-RP-3/pull/1396)
- [verified] Textures load from the addon folder by path on 2.5.x. Allowed formats are BLP, TGA and JPEG at power-of-two sizes. PNG was added in retail 10.0.7 and must be referenced with its '.png' extension; whether PNG works on 2.5.x is unverified.: DisasterZone ships 66 .blp and 11 .tga files and uses them in game, e.g. UI\StrategyMap3D.lua:72-73 DISC_TEX/RING_TEX = "Interface\\AddOns\\DisasterZone\\Media\\Strategy\\disc"/"ring". The SetTexture wiki says custom images must be BLP, JPEG, PNG or TGA at power-of-two sizes, with PNG supported since 10.0.7. (C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone\UI\StrategyMap3D.lua:72 ; https://warcraft.wiki.gg/wiki/API_TextureBase_SetTexture)
- [verified] ModelSceneActor on 2.5.x has no API to set or replace a texture. The only model texture override is Model:ReplaceIconTexture(asset) on the old Model widget, which fills only texture type 14, TEX_COMPONENT_ITEM_ICON.: The full ModelSceneActorBase function list in the 2.5.x docs has no texture setter. The list is: ClearModel, GetActiveBoundingBox, ..., SetDesaturation, SetGradientMask, SetGradientMaskWithDyes, SetModelByCreatureDisplayID/FileID/Path/Unit, SetParticleOverrideScale, SetSpellVisualKit, ... TryOn. SimpleModelAPIDocumentation.lua:403 defines ReplaceIconTexture(asset: FileAsset). wowdev's M2 texture types list type 14 as 'Used on inventory art M2s (2): ui-button.m2 and forcedbackpackitem.m2 (CSimpleModel_ReplaceIconTexture("texture"))'. (https://github.com/Gethe/wow-ui-source/blob/classic_anniversary/Interface/AddOns/Blizzard_APIDocumentationGenerated/SimpleModelAPIDocumentation.lua ; https://web.archive.org/web/20251204222322/https://wowdev.wiki/M2 (Texture Types))
- [verified] In 2.5.6, model files are chunked MD21 (version 274). They find their skin through SFID (a FileDataID) and their textures through TXID (FileDataIDs), with the texture filenames left empty. A custom M2 cannot reliably point its SFID at a loose .skin, because the skin only has a temporary negative ID that shifts with other files. This skin lookup is the main technical risk.: I parsed C:\Users\emilo\CDLoot-dev\dev\art\wmo\191671.m2, downloaded from the 2.5.6 build via wago. Its chunks are [MD21 119648, TXAC, EXP2, PGD1, LDV1, SFID 4, TXID 48], with version 274 and 12 textures, all type 0 with name length 0. wowdev says SFID 'used to be filename based, using ${basename}${view}.skin'. WoWUIBugs #287 shows the local IDs shift between restarts. (C:\Users\emilo\CDLoot-dev\dev\art\wmo\191671.m2 ; https://web.archive.org/web/20251204222322/https://wowdev.wiki/M2 (Chunks/SFID) ; https://github.com/Stanzilla/WoWUIBugs/issues/287)
- [uncertain] The 2.5.6 M2 loader may still find skins by file name for a legacy non-chunked MD20 file, or for an MD21 file without an SFID chunk. That fallback would make custom skins possible, but it is unproven.: wowdev (Legion note): 'If the first magic is MD20, it will be loaded just fine like it did previously.' The 2.5.6 exe contains both the CVar text 'forceLODCheck: If enabled, we will skip checking DBC for LOD count and every m2 will scan the folder for skin profiles' and 'LoadSkinProfile failed because of no skin profile %s fileDataID %d', so a folder scan and a FileDataID lookup both exist in the code. wowdev also notes that 9.1.5 'expects M2Array filename to be zeroed in order to lookup BLP FileDataIDs from TXID', which means filename-based textures are still honoured when a name is present. (https://web.archive.org/web/20251204222322/https://wowdev.wiki/M2 ; C:\World of Warcraft\_anniversary_\WowClassic.exe (strings; dump at C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\aa52e4d4-c087-4769-a09e-98ce81f5d755\scratchpad\exe_strings3.txt lines ~1764738-1764916))
- [likely] A custom room M2 needs no custom textures: its TXID chunk can reference Blizzard's own WMO texture FileDataIDs, which are stable and already known to gen_rooms.py. WMO vertex colours (baked lighting) cannot be carried by M2 vertices; they would have to be baked into shipped BLPs or dropped (use unlit materials).: TXID is 'struct { uint32_t fileDataID; } textureID[]' (wowdev). The cached 2.5.6 M2 uses TXID for all 12 textures. The M2 vertex layout (m2_tools.py docstring) has position, bone weights and indices, a normal and 2 UVs, and no colour. (https://web.archive.org/web/20251204222322/https://wowdev.wiki/M2 ; C:\Users\emilo\CDLoot-dev\dev\generators\m2_tools.py:1-13)
- [likely] The stock retail client has blocked loose files that override game files since about 7.3. Model swapping needed a patched client (the Arctium launcher maps fileId to file path through a hook in the file-load function). This concerns replacing CASC files, not new files under Interface\AddOns, so it neither confirms nor rules out custom addon models.: The OwnedCore thread 'Arctium WoW Client Launcher (Custom file loading on retail)' (Nov 2017) offers 'Custom file loading' for 7.3.2/7.3.5/8.0.1 and warns it violates the ToS. The Arctium source ModLoader.cs hooks a pattern named CustomFileIdHook ('Inside the file load func') and reads 'fileId;filePath' mapping files. (https://web.archive.org/web/20220611170824/https://www.ownedcore.com/forums/world-of-warcraft/world-of-warcraft-model-editing/wow-me-tools-guides/646059-arctium-wow-client-launcher-custom-file-loading-retail.html ; https://github.com/brian8544/Arctium-Launcher/blob/HEAD/src/ModLoader.cs)
- [likely] No UI model widget or actor can load a WMO. Every model setter resolves to M2 (or M3) files, so the only way to render the room natively in a ModelScene is to convert it into custom M2 file(s).: The documented setters are SetModel(ModelAsset), SetModelByFileID, SetModelByPath, SetModelByCreatureDisplayID and SetModelByUnit, with no WMO variant. Next to the model cache code in the exe ('FileData', M2Cache.cpp, CM2Shared/CM3Shared) the only extension literals are '.m3' and '.m2'. (2.5.x API docs above ; WowClassic.exe strings around 'hotReloadModels' / 'M2Initialize()')
- [verified] Blizzard's own M2 files (world doodads, GameObject models, spell effects) load by FileDataID on 2.5.x. The missing props such as pillars and braziers could therefore be added natively as actors in the creature ModelScene, where the GPU depth-sorts them against creatures (in-game fact 6). They would still need the existing software occlusion against the textured room.: Games\Trainer\UI.lua:294 and :635 call actor:SetModelByFileID(fdid) for units and effect models. Per project memory, the generator GameObject model (file 191730) was seen in game. WeakAurasModelPaths' TBC list (ModelPathsTBC.lua, about 12,977 fileIds) includes world/... doodad folders such as ahnqiraj, braziers, bookshelves and chandelier, which WeakAuras loads with frame:SetModel(tonumber(fileId)) (WeakAuras.lua:6238). (C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone\Games\Trainer\UI.lua:294 ; C:\World of Warcraft\_anniversary_\Interface\AddOns\WeakAurasModelPaths\ModelPathsTBC.lua ; C:\World of Warcraft\_anniversary_\Interface\AddOns\WeakAuras\WeakAuras.lua:6232-6240)
- [likely] The client writes model load errors to Logs\Model.log, which makes it a ready diagnostic for the test. The file exists in the user's install (0 bytes, created at the last launch), and the exe contains the matching error strings.: C:\World of Warcraft\_anniversary_\Logs\Model.log exists (0 bytes, 2026-10-05 11:38). The exe contains 'Logs\Model.log', 'Corrupted model: %s', 'Failed to initialize model: %s', 'LoadSkinProfile failed because of no skin profile %s fileDataID %d', 'Failed to choose skin profile: %s' and 'Model not loaded'. (C:\World of Warcraft\_anniversary_\Logs\Model.log ; WowClassic.exe strings)
- [verified] The installed client is TBC Anniversary 2.5.6.69795 (product wow_anniversary; the exe's static data tag is WOWSTATIC_2_5_6_68184), not 2.5.5. API availability above was checked against the classic_anniversary docs and this exe.: .build.info lists Version 2.5.6.69795 and Product wow_anniversary. The exe contains the string 'WOWSTATIC_2_5_6_68184'. (C:\World of Warcraft\.build.info ; C:\World of Warcraft\_anniversary_\WowClassic.exe)
- [uncertain] 2.5.x ModelScene has two calls relevant to the depth problem: SetAllowOverlappedModels(bool), which is undocumented and was added in retail 11.2.5, and Project3DPointTo2D(x, y, z) -> x2d, y2d, depth. The first might change how overlapping model scenes share depth (in-game fact 4); the second can check the addon's Lua projection against the engine's own.: FrameAPIModelSceneFrameDocumentation.lua in classic_anniversary has Project3DPointTo2D at line 331 and SetAllowOverlappedModels at line 350, with no Documentation string. The wiki says SetAllowOverlappedModels was added in 11.2.5 with no description. Both appear in the exe's usage strings. (https://github.com/Gethe/wow-ui-source/blob/classic_anniversary/Interface/AddOns/Blizzard_APIDocumentationGenerated/FrameAPIModelSceneFrameDocumentation.lua ; https://warcraft.wiki.gg/wiki/API_ModelScene_SetAllowOverlappedModels)
- [likely] If custom M2s load, the room drawn as one or more M2 actors in the same ModelScene as the creatures, with the same near/far clip, gives per-pixel correct depth between room and models on the GPU. That holds because one scene with one clip range sorts correctly (in-game facts 4-6). It also removes the face budget and the copies/occluder approximation. Constraints:
- index buffers are uint16 per skin, so large rooms are split into chunks of at most about 65k vertices;
- the header bounding box and radius must enclose the geometry;
- use the M2 material flags unlit 0x01, unfogged 0x02 and two-sided 0x04 for one-sided walls;
- water uses alpha-blend materials;
- actor scale must stay 1 (position is multiplied by scale, fact 7);
- particles are not clipped (fact 2), which does not matter for static room meshes.
Shipping new binary files needs a full release, not a Lua hot patch.: This follows from the in-game facts given in the task (4, 5, 6, 7), the M2/.skin format (skin vertex and index arrays are uint16 M2Arrays; wowdev M2/.skin header) and the project's hotpatch rule that room and binary files require a full release (project memory). (Task context facts 4-7 ; https://web.archive.org/web/20251104040529/https://wowdev.wiki/M2/.skin)

Open questions:
- The deciding in-game test, run once after copying files into C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone\Test\ and doing /reload (or a full restart to be safe). Variant A: a byte copy of a small 2.5.6 Blizzard M2 (for example C:\Users\emilo\CDLoot-dev\dev\art\wmo\191671.m2) with its vertex positions scaled 3x, keeping its real SFID/TXID. Variant B: the same model written as a non-chunked MD20 file (version 274, no chunks) plus 'b00.skin'. Variant C: an MD21 file with the SFID chunk removed plus 'c00.skin'. For each path p: /run local s=<the board's ModelScene>; local a=s:CreateActor(); print(C_UIFileAsset.IsLooseFile(p), C_UIFileAsset.GetFileID(p), a:SetModelByPath(p), a:IsLoaded(), a:GetModelFileID(), a:GetModelPath(), a:GetActiveBoundingBox()). Then look at it on screen and read Logs\Model.log. If A shows 3x larger, the client loads loose M2 bodies. If B or C also shows, custom geometry, and therefore the room as M2, works. If A fails while IsLooseFile is true, the loader rejects loose models.
- If B and C both fail, does an SFID entry of 0, or a loose skin's current negative ID read with C_UIFileAsset.GetFileID, load at all? That would only matter as a diagnostic, because negative IDs shift whenever other files appear (for example Errors\*.txt after a crash) and so cannot be shipped.
- Does a custom M2 that keeps texture filenames (no TXID, for example Interface\AddOns\DisasterZone\Rooms\x.blp) get its textures? Pointing TXID at Blizzard WMO texture FileDataIDs avoids this question, but baked-lighting textures would need it.
- What does ModelScene:SetAllowOverlappedModels(true/false) change, if anything, about the shared depth buffer between scenes (in-game facts 4-5)? It is undocumented in both retail and 2.5.x.
- Is PNG accepted for textures on 2.5.x (retail 10.0.7+ feature)? This is minor; BLP and TGA are confirmed to work.

### Bottom line: all ModelScenes (and Model frames) draw into one shared depth buffer

Bottom line: all ModelScenes (and Model frames) draw into one shared depth buffer. Two outside sources confirm the user's in-game finding. The client exposes one per-scene switch for it, ModelScene:SetAllowOverlappedModels, which exists in 2.5.5. UI textures are never depth-tested, so they always paint over a scene on a lower level.

The most reliable way to get per-pixel room/model depth is a depth pre-pass ("sandwich"), drawn in this order inside the view, all in one strata:
1. A ModelScene on the lowest level holding static, invisible stand-ins ("proxies") for the room. Each is a unit-cube actor placed just behind an opaque room face.
2. An opaque full-view backdrop texture, which hides the cubes' colours everywhere.
3. The existing BSP room textures, unchanged.
4. The creature and player scene(s), plus M2 doodads as real actors. These must use the same camera, FOV, near/far clips and frame rectangle as the proxy scene.

The GPU then depth-tests every model pixel against the room's real depth. This replaces the occluder boxes, the copies, the slicing and the backdrop scene for oversized bosses. Particles are depth-tested too.

Two facts are still missing:
- (T1) Does the depth written by scene 1 survive the UI textures drawn between it and scene 4? Nothing documents this, and no test so far had UI textures between two scenes.
- Usable proxy geometry. The stock model spells/unitcube.m2 (file ID 167145) is an exact ±0.5 opaque cube that writes depth, and the 2.5.6 client lists it. No stock opaque flat square exists: every flat quad found is a camera-facing billboard.

Several methods do not give invisible depth occluders:
- Actor alpha below 1 almost certainly stops depth writes (two independent viewer reimplementations show this), and alpha 0 draws nothing.
- No stock invisible model that writes depth is known.
- Collision models have no render batches.

The single highest-payoff experiment (T6) is loading a byte-for-byte copy of a game .m2 from the addon folder with SetModelByPath. If that works, whole rooms could ship as M2 files that reference game textures. The GPU would then draw room, doodads and creatures together with exact depth and no face budget. Earlier evidence is weak, so do not plan on it.

Copies stay as the fallback, and also cover the few see-through room surfaces (alpha-keyed and blended pieces).

Two existing notes are now wrong and should be corrected: dev/docs/trainer_renderer_v2/findings.md:89 and the comment at View.lua:266-268.

- [verified] ModelScenes and Model frames write into ONE shared depth buffer. It is not cleared per scene, per frame level, or by creation order. A model in a later-drawn scene is depth-tested against every model drawn earlier, as if all were seen by the same camera.: In-game SceneTest (UI/StrategyMap3D.lua:1462-1534): two scenes on levels base+3 and base+6, both with clips 0.5/500. The player stayed in front in all 4 order/level setups.

An independent addon author found the same with PlayerModel unit-frame portraits. Observation 2: if model A is below model B in frame space, A takes part in occluding B. Observation 3: the effect follows the shared camera space.

The flag in the next finding exists specifically to opt out of this.

These are now outdated:
- dev/docs/trainer_renderer_v2/findings.md:89 says actors in different scenes never depth-test each other.
- The comment at Render3D/View.lua:266-268 blames 'Brutallus drawn over you' on in-scene sorting. That case was really different clip ranges (fact 5). (https://github.com/3zeah/AnimatedDefaultPortraits (README, observations 1-3); UI/StrategyMap3D.lua:1462-1534; C:\Users\emilo\CDLoot-dev\dev\docs\trainer_renderer_v2\findings.md:89; Render3D/View.lua:266-268)
- [likely] ModelScene:SetAllowOverlappedModels(bool) and GetAllowOverlappedModels() exist in the 2.5.5 client. They are the only documented per-scene control over this depth sharing. The default is false (shared). Blizzard turns it on for shop model scenes. Its exact meaning is not documented. Most likely, a scene with true draws its models without being cut by depth that earlier model frames left (a per-scene depth clear or isolation).: The 2.5.5 API docs list GetAllowOverlappedModels and SetAllowOverlappedModels(allowOverlappedModels bool).

ModelSceneMixin.lua:11-12 calls SetAllowOverlappedModels(true) when self.allowOverlappedModels is set. ModelSceneMixin.xml:20-21 sets it for StoreModelSceneMixinTemplate with the comment '<!-- CLASS-44103: Automatically allow overlapped models for shop scenes -->'.

The wiki says it was added in retail 11.2.5 (2025-10-07).

How to confirm (T3): rerun SceneTest with the farther creature's scene on the higher level and SetAllowOverlappedModels(true). If the creature now covers the player, true means 'ignore earlier depth'. Also print GetAllowOverlappedModels() on a fresh scene.

Use: leave it false on the proxy and creature scenes. If it does act as a depth clear, it is also the tool that would make banded depth slicing correct. (https://raw.githubusercontent.com/Gethe/wow-ui-source/2.5.5/Interface/AddOns/Blizzard_APIDocumentationGenerated/FrameAPIModelSceneFrameDocumentation.lua (lines 36, 349); https://raw.githubusercontent.com/Gethe/wow-ui-source/classic_anniversary/Interface/AddOns/Blizzard_SharedXML/ModelSceneMixin.xml (lines 18-23) and ModelSceneMixin.lua (lines 11-13); https://warcraft.wiki.gg/wiki/API_ModelScene_SetAllowOverlappedModels)
- [likely] Each scene stores depth relative to its own near/far clips, as a standard perspective projection does. Depth from scenes with different clips cannot be compared, which is why depth slicing failed. Every scheme that relies on cross-scene depth needs identical camera, FOV, near/far and viewport rectangle in all scenes.: With D3D-style depth z = f/(f-n)·(1-n/z):
- Fact 5's far model at about 40 yd, in the scene clipped 34.8-51.2, stores 0.41.
- The player at 6.9 yd, in the scene clipped 5.5-8.25 and drawn later, gets 0.61, fails the test and is hidden. That is exactly what was seen.
- With reversed depth the values are 0.59 and 0.39, with the same outcome.

The SliceTest 'joins seamlessly' result (StrategyMap3D.lua:1607-1691) does not contradict this. Back faces are culled, so the far half of a roughly convex body adds few camera-facing pixels, and that test barely depended on cross-scene depth.

Project3DPointTo2D returns a third value, 'depth', in 2.5.5. T7: print it for a fixed point while changing the near/far clips to see the normalisation directly. (FrameAPIModelSceneFrameDocumentation.lua (2.5.5) lines 330-345; UI/StrategyMap3D.lua:1607-1691; Render3D/View.lua:377-396 (SetSliceClips))
- [verified] UI textures are never depth-tested against models. A region on a higher frame level always paints over a ModelScene on a lower level. Inside one frame, ModelScene:SetDrawLayer and Model:SetModelDrawLayer place the model among that frame's own texture layers. Two items on the same level, layer and sublevel have no defined order.: In game, the copies method works: room copies at copy0 and above hide models in the scene at LV.scene (View.lua:21-22, StrategyMap3D.lua:40).

Blizzard's TBC shop uses StoreCardDetail_SetLayerAboveModelScene to raise buttons above a card's model: self:SetFrameLevel(modelScene:GetFrameLevel()+1) at Blizzard_StoreUISecure.lua:4274-4279.

The LFG frame puts a ModelScene in drawLayer BACKGROUND under its OVERLAY textures (findings.md:89-93).

The 2.5.5 docs list ModelScene SetDrawLayer(layer) and GetDrawLayer() returning layer and sublevel. (https://raw.githubusercontent.com/Gethe/wow-ui-source/classic_anniversary/Interface/AddOns/Blizzard_StoreUI/TBC/Blizzard_StoreUISecure.lua (4274-4279); FrameAPIModelSceneFrameDocumentation.lua (2.5.5) line 434; Render3D/View.lua:21-22)
- [uncertain] Unknown, and the deciding question for the recommended design: does depth from a lower scene survive UI textures drawn between it and a higher scene? Unknown too: do UI textures write depth (for example a 'far' value), and is depth cleared when the frame strata changes?: No source documents any of this. Fact 4 had nothing drawn between the two scenes: only the frame's background texture below both and the info text on the frame's own level.

CLASS-44103 (shop scenes needing to be allowed to overlap other models) hints that depth survives ordinary UI between model frames, possibly across strata, but does not prove it.

T1 'sandwich test':
- Scene Z at level +2 holds an opaque model (for example the unit cube scaled to 6, or a big creature) 20 yd away.
- An opaque full-rect SetColorTexture at level +4 covers it.
- Scene C at level +6 holds the player 35 yd away, directly behind Z's model.
- Same camera and clips in both scenes.
- Pass: the player has a hole the exact shape of Z's model, with grey showing through.
- Fail: the player is whole.

Run T1 in four variants:
1. A plain frame.
2. Inside a frame with SetClipsChildren(true), like the board's view (StrategyMap3D.lua:111). That frame flattens its render layers.
3. The grey texture set to blend modes DISABLE, ALPHAKEY and BLEND in turn: Room.lua:91 uses all three.
4. Z in a lower strata than C, which tells whether strata changes clear depth. (https://raw.githubusercontent.com/Gethe/wow-ui-source/classic_anniversary/Interface/AddOns/Blizzard_SharedXML/ModelSceneMixin.xml; UI/StrategyMap3D.lua:111 and 1462-1534; Render3D/Room.lua:91)
- [likely] M2 material flags are:
- 0x1 unlit
- 0x2 unfogged
- 0x4 two-sided (no back-face culling)
- 0x8 depth test off
- 0x10 depth write off

Blend modes are 0 Opaque, 1 AlphaKey, 2 Alpha, 3 NoAlphaAdd, 4 Add, 5 Mod, 6 Mod2x, 7 BlendAdd. Two independent viewer reimplementations decide depth write and depth test from these flags alone, whatever the blend mode. Opaque and AlphaKey batches write depth. AlphaKey throws away pixels below its alpha threshold, so those pixels write no depth. Blended effect batches almost always carry 0x10.: WebWowViewerCpp m2Object.cpp:1944-1946:
  depthWrite = !(flags & 0x10)
  depthCulling = !(flags & 0x8)
  backFaceCulling = !(flags & 0x4)
The blend-mode table is at lines 95-106.

wow.export M2RendererGL.js:1584-1601 does the same: 0x04 turns culling off, 0x08 turns depth test off, 0x10 turns depth write off. Line 1579 uses 0x1 for unlit. Its GLContext.apply_blend_mode (lines 248-308) gives Mod as DST_COLOR·src, so a white texel leaves the screen unchanged.

wowdev M2/Rendering (seen through a search snippet; the page sits behind a Cloudflare check) gives the AlphaKey threshold as 224/255 × alpha.

Files I parsed (latest copies from wago.tools):
- 500x500_invisibleplane.m2 (1414903): Alpha blend with flags 0x12, so no depth write.
- collision_pcsize.m2 (197122): Add blend with 0x10, and its skin has 0 batches.

This comes from the reimplementations, not from Blizzard's client code. (https://github.com/Deamon87/WebWowViewerCpp/blob/master/wowViewerLib/src/engine/objects/m2/m2Object.cpp (L95-106, L1944-1951); https://github.com/Kruithne/wow.export/blob/main/src/js/3D/renderers/M2RendererGL.js (L1579-1601); https://github.com/Kruithne/wow.export/blob/main/src/js/3D/gl/GLContext.js (L248-308); https://wowdev.wiki/M2/Rendering)
- [likely] An actor with SetAlpha below 1 almost certainly writes no depth. At alpha 0 it is not drawn at all. So actor alpha cannot produce invisible occluders.: WebWowViewerCpp gives every Opaque or AlphaKey batch a second, 'forced transparency' material using GxBlend_Alpha (m2Object.cpp:1823-1829, 1861-1867). For any override blend above AlphaKey it sets depthWrite = false (1947-1950). It uses that version when final transparency is below 0.999 and skips the mesh below 0.0001 (2076-2085).

Fact 3 (scene SetAlpha(0) did not reliably stop drawing) points to frame alpha not taking this model-alpha path.

T2: Scene A on the lower level has a creature in front at actor alpha 1, 0.5, 0.01 and 0 in turn. Scene B on the higher level has a creature behind it, with the same clips. Check whether B is cut in the shape of A's silhouette at each alpha. (https://github.com/Deamon87/WebWowViewerCpp/blob/master/wowViewerLib/src/engine/objects/m2/m2Object.cpp (L1823-1867, L1947-1950, L2069-2085); Render3D/View.lua:330-341)
- [verified] No stock model is known to draw nothing visible while still writing depth. In theory, an unlit Mod-blend (dst×src) batch with a white texture and without flag 0x10 would do it. That would need a scan of all M2s and is unproven in the real client. The recommended design does not need such a model.: Parsed from wago.tools:
- Collision/invisible models have no render batches or are blended without depth write: collision_pcsize 197122 (0 batches); 500x500_invisibleplane 1414903 (Alpha, flags 0x12).
- The only opaque 4-vertex squares found are camera-facing billboards (bone 0 flag 0x8): ceilingdustemitter.m2 199935, lavasmokeemitter.m2 199957, spellobject_invisibletrap.m2 2199319 and 2199509. They turn to face the camera, so they cannot model walls. (https://wago.tools/api/casc/<fdid>?download (parsed with the scratch script m2probe.py); flat-model scan over https://wago.tools/db2/ModelFileData/csv?build=2.5.6.69795)
- [verified] A usable proxy primitive exists: spells/unitcube.m2, file ID 167145. It is an exact unit cube (±0.5, 24 vertices, 12 triangles) with one Opaque material, flags 0x4 (two-sided; depth test and write on), and texture 167204. The Anniversary client lists it: ModelFileData for build 2.5.6.69795 gives a GeoBox of ±0.5. Its centre is the origin, so the client's sideways GeoBox centring does not move it. No usable opaque flat square exists among the 14,772 ModelFileData models: 92 flat ones scanned, every opaque quad is a billboard.: Parse of the file:
- box (-0.5,-0.5,-0.5, 0.5,0.5,0.5)
- materials [('0x4','Opaque')]
- skin 492738: 36 indices, 1 batch

ModelFileData CSV row: '-0.5,-0.5,-0.5,0.5,0.5,0.5,167145,0,0,18928'.

Other primitives:
- errorcube.m2 166046: opaque and unlit (0x1). Its 2.5.6 GeoBox z of 0 to 0.278 differs from the copy I parsed.
- collisionwallpvp01.m2 200293: opaque slab, 0.52 × 11.08 × 0.29 yd, flags 0.

Caution: WoWUIBugs #67 shows that SetModelByFileID with a non-model ID (133755) crashes the client. Only pass IDs confirmed to be M2 files present in the 2.5.x data. (https://wago.tools/api/casc/167145?download ; https://wago.tools/db2/ModelFileData/csv?build=2.5.6.69795&filter%5BFileDataID%5D=exact:167145 ; https://github.com/Stanzilla/WoWUIBugs/issues/67)
- [likely] RECOMMENDED: the depth pre-pass 'sandwich', which gives per-pixel room/model occlusion done by the GPU.

Layer order, all in one strata and one parent rect:
1. Proxy ModelScene at a level below room0 (for example LV.floor). Scene paused with SetPaused(true). Static unit-cube actors fill the room's solid volume just behind every opaque face.
2. An opaque full-view backdrop texture.
3. The BSP room textures, unchanged.
4. One creature scene holding every creature, the player and M2 doodads. Allow-overlapped stays false.
5. Plates and HUD.

The proxy scene must use identical FOV, near/far and camera; View:ApplyCamera already updates every scene. The backdrop hides cube colours everywhere, including where one-sided walls show nothing.

This removes DISPLAY_PARTS boxes, copies (OCC_SLOTS / COPY_TEX_MAX), slices and the scene0 backdrop scene for oversized bosses.

It works only if T1 passes.: It rests on four facts:
- (a) Depth is shared and persists across scenes (finding 1).
- (b) UI is not depth-tested, so the room textures and backdrop paint over the proxies and the creatures paint over the room (finding 4).
- (c) Opaque M2 batches write depth (finding 6).
- (d) Same clips give comparable depth (finding 3); fact 6 shows box mode already works with all models in same-clip scenes.

Per-frame Lua cost becomes zero for occlusion, because proxies sit in world coordinates and only the scene camera moves. Particles depth-test against the proxies the same way, which also covers the glows that were drawn in every slice (fact 2).

Accuracy depends only on how well the proxies fit:
- Exact on planar faces whose solid corner is at least 90°.
- Sink proxies 2-5 cm into the solid so feet do not z-fight with floors and edges do not bleed.
- Acute corners and organic or terrain surfaces get tiny gaps or tilted-square approximations (under-occlusion of a few cm).

Room.lua's ALPHAKEY and BLEND pieces (Room.lua:91) get no proxies; keep the existing copies for those few. Water: give it proxies to match the current opaque water, or leave it out to see bodies through it untinted. (Render3D/View.lua:21-22, 93-107 (Backdrop), 114-133 (ApplyCamera); Render3D/Room.lua:91 and 1833; UI/StrategyMap3D.lua:40, 657-721, 2071-2094)
- [likely] How the offline generator should build the proxies, and the main risk.

Placement:
- Put cubes behind each opaque face, inside the solid, with one cube face exactly in the room-face plane.
- Align cube edges with every convex edge so nothing pokes into open air.
- Overshoot is allowed past concave edges (floor-to-wall), because that goes into the adjacent solid.
- Keep the cube side no larger than the local solid thickness, found by a ray cast along the inward normal, so cubes do not poke out the other side of thin walls or floors.
- Tile terrain cells with tilted squares that fit each cell's plane.

The main risk is actor count: organic rooms could need thousands of cubes.: Actor scale is uniform only (fact 7; the 2.5.5 actor docs list only SetScale(scale), and Model:SetTransform takes a single-number scale). So flat planes cannot be made from the cube. Correctness only needs proxies to stay inside solids.

To limit cost:
- Merge coplanar faces and use the largest square that fits.
- Optionally show only proxies whose screen box overlaps a model and lies nearer than the model's far depth. Showing extra proxies is harmless.

T5: 250, 500, 1000, 2000 and 4000 paused unit-cube actors in one scene; record GetFramerate(), memory and ms per frame.

Also calibrate the actor's yaw/pitch/roll order. Place the slab (200293) at known angles and compare against Project3DPointTo2D markers at the expected corners. The doodads need the same calibration. (FrameAPIModelSceneFrameActorBaseDocumentation.lua (2.5.5) line 510; SimpleModelAPIDocumentation.lua SetTransform (scale: number); https://wago.tools/api/casc/200293?download)
- [likely] For rooms that look complete, load the rooms' own M2 doodads as real actors in the creature scene: pillars, braziers, statues and chains from the WMO doodad sets and the ADT doodad lists. They then sort per pixel against creatures, and against the room through the proxies. They need no proxies of their own.: Doodad placements use uniform scale, matching the actor's SetScale. Rotations need conversion (quaternion or Euler) to the client's yaw/pitch/roll order, which the calibration above provides.

The project already shows file models this way: the trainer uses SetModelByFileID for spell models and shield generator 191730 (raid-trainer-game memory).

Lighting comes from the scene's light, not the WMO's baked vertex colours. Tune it per room with SetLightAmbientColor and SetLightDiffuseColor.

With copies gone, their frame levels (copy0 and up) and Lua time are free. They could buy a larger face budget than MAX_TRIS 7000 / MAX_NODES 2990. Still to do: ADT liquids (MH2O). (https://raw.githubusercontent.com/Gethe/wow-ui-source/2.5.5/Interface/AddOns/Blizzard_APIDocumentationGenerated/FrameAPIModelSceneFrameActorBaseDocumentation.lua (SetModelByFileID line 393); C:\Users\emilo\CDLoot-dev\dev\generators\gen_rooms.py; https://github.com/Stanzilla/WoWUIBugs/issues/67)
- [uncertain] Highest-payoff unknown: can a custom M2 be loaded from the addon folder with ModelSceneActor:SetModelByPath (present in 2.5.5)? If yes, the true 'absolute best' becomes possible: ship each room as M2 files with real geometry, referencing game textures by file ID, and let the GPU draw room, doodads and creatures with one exact depth buffer and no face budget. If not, the sandwich is the ceiling.: The 2.5.5 docs list SetModelByPath(asset FileAsset, useMips) returning success.

The only public modern attempt with an addon path failed, and the thread was closed (WoWInterface t=57884). The project's earlier decision (findings.md Q7) was 'unproven, don't plan on it'.

The actual hurdle is that modern M2 files refer to their .skin and texture files by file ID. A byte-identical copy of unitcube.m2 keeps those IDs, so the test isolates whether loose .m2 loading works at all.

T6 (needs a full client restart for new files):
1. Copy unitcube.m2 to Interface\AddOns\DisasterZone\Media\Test\cube.m2.
2. Call SetModelByPath on that path and check both the return value and whether the cube is visible.
3. Then stretch one vertex in the copy and load it again, to prove the loose file was read rather than a cached game file. (FrameAPIModelSceneFrameActorBaseDocumentation.lua (2.5.5) line 408; https://www.wowinterface.com/forums/showthread.php?t=57884 ; C:\Users\emilo\CDLoot-dev\dev\docs\trainer_renderer_v2\findings.md (Q7))
- [uncertain] Fallbacks if T1 fails (UI drawn between scenes erases or overwrites depth):
- Find an invisible depth-writing batch (white, unlit, Mod blend, no 0x10) by scanning M2s, and put the proxy scene just below the creature scene, above the room.
- Or test Frame:SetIsFrameBuffer on the room subtree. It renders a frame offscreen and composites it, which might keep the room's textures away from the shared depth. Unverified.
- Otherwise keep box copies.: From the wiki: SetIsFrameBuffer 'Controls whether or not a frame is rendered to its own framebuffer prior to being composited atop the UI'. It was added to Classic in 2.5.2 and needs flattened render layers. Nothing documents its effect on depth.

Mod with a white texel leaves the colour unchanged (wow.export GLContext.js:281-285), and depth write follows 0x10 only (finding 6). (https://warcraft.wiki.gg/wiki/API_Frame_SetIsFrameBuffer ; https://github.com/Kruithne/wow.export/blob/main/src/js/3D/gl/GLContext.js)

Open questions:
- T1 (decisive): does a lower scene's depth survive opaque UI textures drawn between it and a higher scene? Test in a plain frame, inside a SetClipsChildren (flattened) frame, with each texture blend mode (DISABLE, ALPHAKEY, BLEND) and across a strata change.
- T3: what exactly does ModelScene:SetAllowOverlappedModels(true) do in 2.5.5 (clear depth / ignore earlier depth / something else)? What does GetAllowOverlappedModels return on a fresh scene?
- T2: does an actor with alpha 0.5, 0.01 or 0 write depth in the real client? Predicted no.
- T5: frame cost of 250 to 4000 paused unit-cube actors in one ModelScene. Also: how many cubes does a real room need after merging? Have the generator report counts per room.
- T6: does SetModelByPath load a byte-identical copy of a game .m2 from Interface\AddOns, and then an edited copy? A yes would make shipping rooms as M2 files the best approach.
- Calibration: the yaw/pitch/roll order of ModelSceneActor rotations, needed for tilted proxies and doodads. Also confirm spells/unitcube.m2 (167145) loads in the 2.5.5 client; it is listed in 2.5.6 ModelFileData.
- Are particles depth-tested with the same projection as the scene's meshes? They ignore the scene's near/far clips (fact 2), so check a boss glow behind a proxy wall.
- T7: what Project3DPointTo2D's third return (depth) reports as the near/far clips change, as direct proof of per-scene normalisation.
- Does Room.lua cull back faces? The proxy/backdrop layering hides cube colours either way. Only the depth result differs where the room shows nothing, for example a one-sided wall seen from behind.

### Best route: let the GPU do the room-vs-model depth test

Best route: let the GPU do the room-vs-model depth test. Put static "depth proxy" actors in a ModelScene that sits under the room textures. Use the existing View:Backdrop scene0 at lv.floor, which already has the same camera and clip planes. The proxies are unit cubes and one-sided squares that are already in the client. Paint a full-view opaque backdrop and the room textures over them, then draw the creature, doodad and player scenes on top with the same near/far. Facts 4 and 5 say ModelScenes share one depth buffer when their clip ranges match. If that buffer survives the UI textures drawn between scenes (test E3), every creature pixel behind a room surface fails the depth test and the room texture shows through. That is per-pixel occlusion with no copies, no occluder boxes and no per-frame Lua cost for the proxies. How exact it is depends on how well the proxies fit the room: exact for box-like architecture, and for flat polygons whose corners are all 90 degrees or wider. Elsewhere the error is a small sliver whose size you choose, measurable offline with render_check.py's z-buffer truth. WMO doodads can go in as real M2 actors; for example, Black Temple has 3,520 placements of 264 M2s, all in the client. Prior art: no public addon combines ModelScene models with texture geometry and correct occlusion. FreedoomArcade uses Doom's per-column clip arrays plus frame levels. AVR drew SetTexCoord triangles with no occlusion. Scene Machine is a ModelScene editor with 2D texture overlays (no occlusion). X Practice builds raid maps from ModelScenes; its source was not inspected. Blizzard's only 3D environments in the UI are environments authored as single M2 files (the glue and login scenes). No UI API renders WMOs, and none offers depth, stencil, render-to-texture or masks for models. One new lever to test: ModelScene:SetAllowOverlappedModels exists in this client, the addon never uses it, and Blizzard turns it on for scenes with several models. It probably controls the depth sharing behind facts 4 and 5. File presence and geometry were checked against the user's own install (build-uid wow_anniversary, version 2.5.6.69795 — newer than the 2.5.5 the task names), using a read-only local CASC reader I wrote in a temporary folder outside the scratchpad and outside the project: C:\Users\emilo\AppData\Local\Temp\claude\scratch_wago\casc\localcasc.py. Its index files (root.pkl, enc.pkl, m2s.pkl, text.pkl) are in the same folder. To check primitive geometry I also downloaded about a dozen small M2 game files from wago.tools's CASC API, the same source gen_rooms.py uses; these are in C:\Users\emilo\AppData\Local\Temp\claude\scratch_wago\m2. I read nothing into the addon or dev kit and changed nothing there.

- [likely] Recommended method (most reliable per-pixel occlusion): a depth-proxy ModelScene drawn before the room textures, and creature scenes drawn after them, all with the same frame rect, FOV and near/far.: Facts 4 and 5 show model scenes depth-test against each other, and comparisons are valid only when clip ranges match. Fact 5's failure also suggests depth persisted across room textures interleaved between scenes. Order: (1) proxy scene P = existing View:Backdrop scene0 at lv.floor, already under every room piece and set up by the same SetupScene (near 0.5, far 500, FOV 1.1). (2) A full-view opaque texture just above P to hide the proxies' colour, then the room textures in BSP painter order as now. (3) Creature and doodad scene (lv.scene) and player scene (lv.scene2). Creature pixels farther than the proxy depth are rejected, so the room texture below shows. This replaces Room.SetOccluders and the copies (Render3D/Room.lua:2039, UI/StrategyMap3D.lua:658-721, :2087). Proxies are static actors, so camera moves need no per-actor Lua. ModelScene:SetDrawLayer exists (client docs 5244964:435), and Blizzard places a ModelScene at drawLayer BORDER (6686490:133), so scenes are composited inline in UI order, as the existing copies approach already relies on. (C:\Users\emilo\CDLoot-dev\addon\DisasterZone\Render3D\View.lua:80-107 (SetupScene, Backdrop); user's in-game facts 4-6; client file 5244964 interface/addons/blizzard_apidocumentationgenerated/frameapimodelsceneframedocumentation.lua:435)
- [verified] Primitive M2s in the TBC Anniversary client usable as proxies (checked in the local root of build 2.5.6.69795; geometry parsed from local data).: spells/unitcube.m2 FDID 167145: exact cube ±0.5 centred on the origin, 24 verts, 12 tris (skin 492738), one opaque material flagged two-sided (0x4), texture spells/white1.blp (167204), 1 bone, 1 sequence. spells/spellobject_invisibletrap.m2 FDID 2199509 and world/generic/passivedoodads/traps/spellobject_invisibletrap.m2 FDID 2199319: a single 1.389 yd square, 4 verts in the X=0 plane at ±0.694, normal -X, tris (0,1,2),(3,2,1), one-sided opaque (flags 0), white1.blp; wago lists only wow_classic* products for it. spells/errorcube.m2 FDID 166046: 0.278 yd cube, base at z=0, unlit opaque. world/scale/50x50, 100x100, 250x250, 500x500, 1000x1000.m2 = FDIDs 219363, 219357, 219361, 219362, 219356: exact cubes 1.389 / 2.778 / 6.944 / 13.889 / 27.778 yd, base at z=0, opaque, texture world/scale/1_null.blp 219358. world/generic/pvp/collisionwall/collisionwallpvp01.m2 FDID 200293: exact box 0.521 x 11.077 x 0.291, opaque. Not in this client: retail blockout pieces (world/blockout/*, 12ph_blockout_cube01 4992775), collision_rectangle 1488891, 500x500_invisibleplane 1414903, world/scale/*sphere. (Local CASC: C:\World of Warcraft\Data, build config 6761dba8cfd072ee16accae41941bd11 (build-uid wow_anniversary, 2.5.6.69795), read with C:\Users\emilo\AppData\Local\Temp\claude\scratch_wago\casc\localcasc.py; names from https://wago.tools/files?search=unitcube (and =spellobject_invisibletrap, =world/scale/))
- [likely] No shipped primitive is an 'invisible but depth-writing' model, and making an actor transparent probably turns its depth write off. So proxies must be opaque and hidden by UI textures drawn over their scene, not made invisible inside the creature scene.: I scanned all 14,770 M2 files in the anniversary root; 3,668 have 64 vertices or fewer. None of those use only Add/Mod blends with depth write enabled (M2Material flag 0x10 clear). Deamon87's WebWowViewerCpp m2Object.cpp ~line 1944: depthWrite = !(flags & 0x10); when a transparency override applies (actor alpha below 1) and the blend is above AlphaKey, depthWrite = false. That matches fact 3 (SetAlpha(0) is not a usable switch). (https://raw.githubusercontent.com/Deamon87/WebWowViewerCpp/master/wowViewerLib/src/engine/objects/m2/m2Object.cpp (lines ~1940-1952); local scan m2s.pkl)
- [likely] ModelScene:SetAllowOverlappedModels(bool) exists in this client, is unused by DisasterZone, and Blizzard enables it for scenes with several or overlapping models. It is the most likely switch behind the shared-depth behaviour in facts 4 and 5.: Client docs 5244964:350 (Set/GetAllowOverlappedModels). blizzard_sharedxml/modelscenemixin.lua (5613716):12 sets it when the allowOverlappedModels key is set. scriptanimatedmodelscene.lua (7290499):24-26 comment: 'Automatically allow overlapped models for these types of scenes. Could be optimized to only enable when there are multiple models.' blizzard_storeui/classic/blizzard_storeuiinsecure.lua (5613069):24,29 toggles it with the note 'CLASS-44103: Automatically allow overlapped models for shop scenes'. The same KeyValue appears in modelscenemixin.xml (5613247):21, blizzard_catalogshop.xml (6686490):133 and blizzard_catalogshop_sharedproductcards.xml (7513302):43. Added in retail patch 11.2.5. A grep of DisasterZone finds no use. Its exact meaning is undocumented: either per-scene depth isolation or shared depth between models. (Local client Lua/XML (FDIDs above, names via wago.tools); https://warcraft.wiki.gg/wiki/API_ModelScene_SetAllowOverlappedModels ; https://warcraft.wiki.gg/wiki/Patch_11.2.5/API_changes)
- [verified] Other UI APIs that matter here; there is no depth, stencil, render-to-texture or model-mask API.: ModelScene: SetCameraNearClip/FarClip, Project3DPointTo2D (returns x, y, depth), SetViewInsets (545), SetViewTranslation, SetDrawLayer, SetFogColor/Near/Far, SetDesaturation, SetPaused, SetCameraOrientationByAxisVectors. Actor (5264241): SetYaw/SetPitch/SetRoll, SetScale, SetUseCenterForOrigin, SetModelByFileID, SetModelByPath (420), SetAnimation(anim, variation, animSpeed, animOffsetSeconds), SetParticleOverrideScale, SetPreferModelCollisionBounds (504), SetSpellVisualKit. Frame (4637218): SetClipsChildren (1058), SetFlattensRenderLayers (1106), SetIsFrameBuffer (1215: 'rendered to its own framebuffer prior to being composited'). AddMaskTexture exists only in SimpleTextureAPI (4637233), so masks cannot cut models. A search of all client API docs found no Depth, Stencil or RenderTarget functions. (Client docs 5244964, 5264241, 4637218, 4637233 (blizzard_apidocumentationgenerated/*); https://warcraft.wiki.gg/wiki/API_Frame_SetIsFrameBuffer)
- [likely] How exact cube and square proxies can be.: Actors allow only similarity transforms (uniform scale + yaw/pitch/roll + position; fact 7). A union of cubes with side = the smallest box dimension, overlapping as needed, reproduces any oriented cuboid exactly (pillars, steps, slabs, box rooms). A planar convex facet whose interior angles are all 90 degrees or more can be covered exactly by squares placed entirely inside it, aligned to its edges. Acute corners and curved walls leave slivers no larger than the smallest square used. One-sided squares (2199509) cause no volume leaks and are back-face culled. Recipe: merge coplanar triangles into polygons, cover each from its front side only, and inset 1-3 cm into the surface. If the board's cam.mirror flips y, compute placements and front faces in scene space. Offline check: render_check.py already z-buffers the truth (render_truth, tools/render_check.py:570). Adding a proxy z-buffer gives the per-pixel error before any in-game test. (Geometric reasoning; C:\Users\emilo\CDLoot-dev\dev\tools\render_check.py:570; View.lua:110 (SY mirror))
- [verified] Doodads can make rooms complete, with exact model-vs-model occlusion. Some water is itself an M2 doodad.: gen_rooms.py and wmo_tools.py never read MODD/MODI/MODS (only MOHD counts). The Black Temple root (dev/art/wmo/108713.wmo) has 3,520 MODD placements of 264 unique M2 FDIDs, all in the anniversary root. The biggest include bt_sewerwater_bossroom.m2 (191471, the animated boss-room water), bt_sewergutter_hall.m2 (191468) and large banners. MODD gives position, a quaternion and one uniform scale, so it maps directly to SetPosition (divided by scale), Euler angles and SetScale. (C:\Users\emilo\CDLoot-dev\dev\art\wmo\108713.wmo parsed locally; C:\Users\emilo\CDLoot-dev\dev\generators\wmo_tools.py:17-40)
- [likely] Evidence for the actor rotation convention: Scene Machine maps a quaternion to roll = X, pitch = Y, yaw = Z (standard ZYX) and divides positions by scale.: Actor.lua:29-35: SetPosition(x/s, y/s, z/s); SetRoll(rotation.x); SetPitch(rotation.y); SetYaw(rotation.z); SetScale(s). Quaternion.lua:77-99 uses the standard aerospace ZYX conversion. Pitch sign and handedness still need an in-game check (the addon already auto-detects pitchSign and mirror for the camera, View.lua:163-181). (https://github.com/CucFlavius/scenemachine (scenemachine/src/Objects/GameObject/Actor.lua, src/Objects/Quaternion.lua))
- [likely] Prior art: software renderers with textures exist, but none mixes ModelScene models with texture geometry and correct occlusion. Several names in the task have no trace online.: FreedoomArcade (petllama; Interface 16001 and 120100): a Lua 5.1 port of linuxdoom. Walls are one texture strip per screen column, floors are spans, and sprites are 'quads clipped into column runs, each on its own frame level'. It uses 8-argument SetTexCoord (src/draw.lua:77), Doom's ceilingclip/floorclip and drawseg arrays (src/render.lua:141-149), and a mock WoW API with a software rasterizer (tools/mock_wow.lua). WoWDoom (scbasss): 72 shaded vertical strips. Doom Within (tna0y): a RISC-V emulator, 0.5-2 s per frame. AVR (Olog, WotLK): SetTexCoord-skewed triangle textures, hundreds per frame, drawn over the world with no occlusion; Blizzard broke it in 3.3.5. Scene Machine (CucFlavius): ModelScene actors with gizmos and sprites drawn as textures on top, no occlusion (src/renderer.lua). X Practice (LuaViper, 466k downloads): 'uses World of Warcraft's built-in ModelScene widgets to recreate raid maps'; its occlusion method is unknown and the source was not inspected. Searches for LibWoW3D, Paradox 3D, Mapster 3D and TargetFrame 3D found nothing. (https://github.com/petllama/FreedoomArcade ; https://github.com/scbasss/WoWDoom ; https://github.com/tna0y/wow-doom-within ; https://www.wowinterface.com/forums/showthread.php?t=36189 ; https://www.wowinterface.com/downloads/info16249-AVR.html ; https://github.com/CucFlavius/scenemachine ; https://www.curseforge.com/wow/addons/x-practice)
- [likely] Blizzard renders UI 3D environments only as environments authored as single M2 files (glue scenes). Its in-game UI ModelScenes load single M2s over 2D art and never WMOs.: The anniversary root contains 45 glue environment M2s, e.g. interface/glues/models/ui_mainmenu_burningcrusade/ui_mainmenu_burningcrusade.m2 (131982, 18,071 verts), ui_bloodelf.m2 (131921, 14,217 verts, a box about 385 x 379 yd), ui_human.m2 (131948), ui_characterselect.m2 (343630), and later-expansion ones. In this client's UI code the only SetModelByFileID calls load single assets: catalog entries, housing decorFileDataID (7513303), scripted-animation effect visuals (7290498) and the commentator fanfare. The actor API has only FileID, Path, CreatureDisplayID and Unit setters. No retail UI environment M2s turned up by name (ui_garrison, ui_covenant, ui_transmog and similar match only sounds and icons). (Local CASC root plus a scan of the client's Lua; https://wago.tools/files?search=interface/glues/models)
- [uncertain] A custom room mesh as a loose M2 would make proxies (or whole rooms) exact, but is unlikely to load.: Patch 8.2: 'Non interface\ file paths can no longer be used' (warcraft.wiki.gg FileDataID). SetModelByPath(FileAsset) exists (5264241:420). Modern MD21 files reference skins by FileDataID (SFID), which a loose file cannot have. No addon is known to load a loose M2 on a modern client. (https://warcraft.wiki.gg/wiki/FileDataID ; https://www.wowinterface.com/forums/showthread.php?t=57884)
- [verified] The user's own install can replace wago for exact-build game files. wago's CASC download serves a different version of some primitives.: localcasc.py reads build config, then encoding, then root (MFST) and the data.### archives read-only: 190,763 files, of which 14,770 are M2s. Size differences: unitcube is 1,906 bytes from wago and 1,922 locally; errorcube's origin differs (centred in the wago copy, base at z=0 locally). gen_rooms.py:115-121 currently downloads https://wago.tools/api/casc/<fdid>. (C:\Users\emilo\AppData\Local\Temp\claude\scratch_wago\casc\localcasc.py; C:\Users\emilo\CDLoot-dev\dev\generators\gen_rooms.py:115-121)

Open questions:
- E0: Do ActorSetModelByFileID(167145) (unitcube) and SetModelByFileID(2199509) (square) load and render in 2.5.5/2.5.6? (errorcube 166046 is a safe fallback.)
- E1: Within ONE scene, does a scaled unitcube that half-intersects a creature cut it along a straight line (per-pixel depth), or does one model wholly cover the other (per-model sort)?
- E2: Same as E1 with the cube in scene A at a lower frame level and the creature in scene B, same near/far, then swap the levels: is the occlusion still per-pixel across scenes?
- E3, the decisive one: put a full-frame opaque texture at a frame level between A and B. Does the creature still get a cube-shaped hole showing the texture (depth survives UI textures), or does it draw whole? The proxy method needs the hole.
- E4: Repeat E1-E3 and the fact-5 slicing test with SetAllowOverlappedModels(true) on one or both scenes. Does it isolate scene depth (slicing would then work) or enable shared depth?
- E5: Does a parent frame with SetFlattensRenderLayers(true) + SetIsFrameBuffer(true) give its ModelScene a private depth buffer?
- E6: Cost of 1,000 / 3,000 / 10,000 static unitcube actors in one hidden-under-textures scene (frame time, load time, memory). This sets the proxy budget per room.
- E7: Actor rotation order and pitch sign (test with an asymmetric model), which side of the one-sided square is front, and how the board's mirrored y (cam.mirror) affects both.
- E8: Can SetModelByPath load a loose M2 from Interface\AddOns? Low odds, but if yes, exact custom proxies or whole rooms become possible.
- Water stored as WMO liquid (MLIQ), not as an M2 doodad: how to tint submerged model parts when the water is a texture under the creature scene. One option is a translucent M2 plane in the creature scene.
- X Practice's source was not inspected: downloading the CurseForge zip needs the user's approval. It is the closest prior art for raid maps in ModelScenes.
- Proxy count and error per room: still to be measured offline by adding a proxy z-buffer to render_check.py and comparing it with render_truth.

## Designs

### Native depth: the room as M2 geometry in the creatures' ModelScene (loose room models), with a depth pre-pass sandwich as the fallback

**one_line:** Stop approximating occlusion in Lua. Put the room's depth into the client's own depth buffer by drawing the room as M2 geometry with the same camera and clips as the creatures: custom room M2s loaded from the addon folder if the client accepts loose models (exact, complete rooms), otherwise stock unit-cube proxies drawn under the room textures. One in-game test session picks the path.

**how_it_works:** BASIS
What is known:
- All ModelScenes write one shared depth buffer (fact 4).
- Depth values only compare correctly when camera, FOV and near/far are identical (fact 5).
- UI textures are never depth-tested and paint in frame-level order.
- Actors only scale uniformly.

So the only native way to get per-pixel room/model depth is M2 geometry that matches the room and writes depth. It can sit in the creatures' own scene, or in an earlier scene with the identical projection.

An invisible depth mesh inside the creature scene does not work. Depth-only materials are translucent (Mod/Alpha blend), and the engine draws translucent batches after opaque ones, which is after the creatures.

Fact 5 is also indirect evidence that depth survives UI drawn between scenes. Room.lua SL.Levels puts the far band's slice scene below the room band frames of the middle bands, and the near band's scene above them. The player was still hidden by the far model's depth through those textures, inside the board's SetClipsChildren frame.

MODE A, "room in the scene" (target)
1. A generator reads the installed 2.5.6.69795 client (local CASC, not unpinned wago). It writes each instance region as tiled custom M2 files under Interface\AddOns\DisasterZone\Rooms\<instance>\. Each tile holds WMO groups, terrain, liquids (MLIQ and MH2O) and static doodads (MODD/MDDF, skinned at Stand t=0 with the existing m2_anim evaluator).
2. Geometry is written in scene coordinates (x, mirror*y, z), with winding flipped if mirror = -1. Textures are referenced by Blizzard's own texture FileDataIDs (TXID), so no textures ship.
3. Each header box is made symmetric in x/y, so the client's sideways box-centring (seen on creatures) is a no-op.
4. At runtime there is one actor per tile in the main ModelScene: SetModelByPath(path, useMips=true), scale 1, position = tile origin, yaw 0. Creatures, the walking player (no scene2) and animated doodads (SetModelByFileID) share the scene and its clips, so the GPU depth-tests everything exactly as the game world does.
5. Room.lua stops drawing textures but keeps its mesh for FloorZ, ScreenRay, CameraDistance and walking. Copies, DISPLAY_PARTS occluders, the scene0 backdrop, scene2 and slices are not used in this mode.

There are two encodings:
- A1, own .skin files. Works if loose skins resolve by name (MD21 without SFID, or legacy MD20). Any mesh, many batches per file.
- A2, "skin reuse". Works if only a loose M2 body whose SFID points at a game skin loads. I scanned the local client: static one-bone world model 189641 (skin 494450, no billboard bones, opaque, wrap flags 3) has 4,022 triangles in 1,700 vertex-disjoint pieces, of which 679 are lone triangles and 696 lone quads. A byte copy that rewrites only vertex positions, normals, UVs, header box and TXID lets each piece host one arbitrary room triangle or quad; unused pieces collapse to zero area. That gives about 2,000+ arbitrary room triangles per actor, one texture per actor, so about 25-120 actors for a full room.

Lighting:
- A2 is lit by the scene light through vertex normals.
- A1 can bake the WMO vertex light per batch (constant colour per light level) or through a second texture layer.
- Water is an alpha-blend batch with UV scroll (bodies seen through tinted water), or opaque as today.

Marks are UI lines and cannot be depth-tested:
- If the sandwich test passes, use a "floor split". Walkable floor faces go into a lower visible scene P, the marks are drawn above P, and walls, pillars, doodads, water, creatures and the player go into C above the marks. C then hides marks per pixel. A Lua ray check hides marks under overhanging floors.
- Otherwise, draw marks above C. Their room visibility comes from sampled ray casts against the room mesh, plus the old per-model line copies.

Runtime self-check: a room switches to native mode only when every file has loaded (SetModelByPath success, OnModelLoaded within a timeout, GetModelPath matches). Otherwise that room keeps today's textured renderer and copies. A client that refuses loose models degrades to the current behaviour, never to a broken view.

MODE B, "depth pre-pass sandwich" (loose models fail, depth survives UI)
Inside the board frame, bottom to top:
1. P at parent+1: a paused proxy scene of static unit-cube actors. spells/unitcube.m2 (FDID 167145) is verified in the local client: ±0.5 cube, 24 vertices, one bone with no billboard flag, opaque, two-sided, texture 167204. The squares 2199509 and 2199319 suggested elsewhere are spherical billboards (bone flag 0x8) and unusable.
2. An opaque backdrop texture.
3. The room textures and marks, unchanged.
4. One scene C with every creature, the player and the doodads (game M2s via SetModelByFileID). Same FOV and clips as P; ApplyCamera already moves all scenes.

Model pixels behind a proxy fail the depth test and the room texture below shows. An offline greedy cover places the cubes:
- oriented squares inside each opaque face, inset 2 cm into the solid;
- cube side no larger than the solid thickness, found by an inward ray cast;
- overshoot only across concave edges, or within a tolerance delta.

ALPHAKEY/BLEND pieces get no proxies and keep copies.

DECISION
One test session decides: a loose model loads → Mode A; otherwise the sandwich works → Mode B; otherwise the fallback.

**accuracy:** MODE A
Exact per pixel for room vs model, model vs model, and doodad vs everything, on opaque and alpha-key surfaces. It is the same depth test the game world uses. It does not depend on:
- animation phase (the GPU uses the live pose);
- part boxes;
- Stand-frame-0 poses;
- model centring or placement for occlusion.

Depth precision with near 0.5 is about z²/(0.5·2^24): 0.3 mm at 50 yd, about 1 cm at 300 yd.

What stays imperfect:
- Translucent surfaces (water, glass, additive glows) are sorted per batch/actor by the engine, as in game. One water layer is correct; stacked translucent layers can mis-order.
- Particles behave as in game (assumed depth-tested, not clip-cut).
- Marks are UI:
  - With the floor split they are exact against the room, and against models standing in front of them.
  - A mark lying in front of a model's lower body is covered by that model, as in every UI approach.
  - Without the split, room visibility is exact to the ray-sample spacing (a few px) and visibility against models is approximate.
- Real placement errors (such as the Lurker's offset) now show as true intersections with the geometry.
- A2 lighting is not identical to today's per-piece WMO vertex light.

MODE B
Exact per pixel wherever a proxy reproduces the surface: planar faces with corners of 90° or more, and box architecture. Elsewhere:
- Depth error is bounded by the generator tolerance delta (2-5 cm), so a foot or tail tip within delta of a surface may wrongly show or hide.
- Acute corners and organic faces leave thin uncovered slivers where a model shows through.
- See-through pieces stay approximate (copies).

Project memory says the rooms are mostly organic faces and merging barely helps, so expect "within delta" rather than exact. It is measurable per room offline before shipping: add a proxy z-buffer to render_check and compare it with render_truth.

Both modes remove today's measured errors: 10.35% of Brutallus' pixels, 3.0-3.5% of the Lurker's, and the square cut-outs.

**looks_complete:** MODE A: yes, fully.
- No face budget. MAX_TRIS 7000 / MAX_NODES 2990 are limits of the texture renderer and no longer apply; whole regions ship as tiles.
- Static doodads are baked in (the Black Temple root alone has 3,520 MODD placements of 264 M2s). Animated doodads (banners, braziers with particles) are actors.
- Liquids come from WMO MLIQ and ADT MH2O as real animated surfaces.
- Geometry is read from the installed client. The unpinned wago downloads differ in 101 of 290 WMO groups and have about 9% fewer triangles, which is a likely source of holes.
- Textures are perspective-correct, with no affine warping and no seams.
- Per-frame Lua cost is near zero.
- The Lua room data shrinks to collision, walk and floor data, which eases the 12 MB of packed strings loaded at login.
- Price: an estimated 20-60 MB of binary room files (tiled per instance and shared between encounters), and full releases only (binary files cannot be hot-patched).

MODE B: partly.
- Doodads come back as actors: per-pixel against creatures and hidden by proxies behind walls.
- Holes from the wago mismatch are fixed by the local-CASC rebuild.
- The textured room keeps a face budget. Dropping copies frees up to 1,500 copy textures and their Lua time, which can buy more room faces (measure it).
- Water stays opaque, unless the instance ships it as an M2 doodad (e.g. bt_sewerwater_bossroom.m2).

**fallback:** If no loose model loads AND depth does not survive UI drawn between scenes, there is no native path to correct room depth. In that case:

1. If test 3 shows that SetAllowOverlappedModels(true) isolates each scene's depth, depth slicing (already built behind `/dz 3d slices`) becomes correct: same-scene sorting within a band, frame-level order between bands. Its error is bounded by band thickness, so it is not per-pixel exact.
2. Otherwise keep today's box mode, but feed it better occluders built offline from the true skinned mesh:
   - per-bone convex hulls, measured at 0.05-0.28% wrong pixels against 3-10% today;
   - a pose frozen with SetAnimation(anim, 0, 0, t) so the hulls match what is drawn;
   - opaque and alpha-key triangles only (this fixes Kil'jaeden's point boxes).
3. Doodads still come back as actors in the creature scene, sorted per pixel against creatures and given hull occluders against the room.

Independent of mode, rebuilding the rooms from the installed client instead of unpinned wago downloads should close the holes caused by the 101 mismatched WMO groups.

**reliability_risks:**
- Loose custom models: there is no public proof either way on CASC clients (the only failure report is a 2020 private-server thread). The loader may require a ModelFileData row or refuse loose M2 files outright, which kills Mode A (test 1 decides).
- Client crash on unexpected M2 data: WoWUIBugs #67 shows SetModelByFileID with a non-model ID crashes. So: a strict offline validator, test variants one at a time (legacy MD20 last), and never pass WMO IDs to SetModelByFileID.
- Loose files are indexed only at startup or /reload, and their temporary negative FileDataIDs shift whenever other files appear (Errors\*.txt, cache files). Never reference a loose file by ID, for example SFID pointing at a loose skin; use paths only.
- Skin reuse (A2) depends on Blizzard not changing model 189641 / skin 494450. It is pinned to the local build, and the runtime load check falls back to textures if it ever breaks.
- Handedness: to_room in gen_rooms.py is a proper rotation, but the Illidan note suggests cam.mirror = -1 in game. The generator must write scene coordinates with matching winding. Game doodads keep their own handedness and could appear as mirror images relative to the room (test 6).
- The client centres creature models sideways on their box. If it does the same for file models, room tiles are covered by x/y-symmetric header boxes, but doodad actors need V:ModelCentre-style compensation.
- ModelScene culling of very large actors (by origin, distance or LOD) is undocumented. Tile with local origins and check walking inside the room.
- Depth is shared with every model frame drawn earlier in the UI frame (3D portraits, other addons' models). Their depth, in their own projection, can punch holes where they overlap the board. Today's box mode has the same exposure. SetAllowOverlappedModels(true) on the first scene may clear it (test 3).
- Mode B actor count: organic rooms could need thousands of cubes, and the cost per actor is unknown (a retail report says one rendered model can cost about 10 FPS). Create them in batches across frames to stay under 'script ran too long'.
- Mode B over-occlusion: any proxy that pokes into open air hides models wrongly. An offline proxy-vs-truth z-buffer check is mandatory for every room.
- Async model loading gives transient wrong occlusion. Stay in the old mode until every room or proxy model reports loaded.
- Marks are UI and can never be fully depth-correct against models. Their correctness against walls in Mode A also depends on the sandwich test.
- Mode A changes the room's look (scene lighting, real textures). It needs the user's sign-off, and the textured renderer must stay as the fallback.
- Binary room files cannot be hot-patched. Every room change means a full release with a larger download.

**depends_on_unverified:**
- SetModelByPath loads a loose .m2 under Interface\AddOns whose SFID and TXID point at game files (enables Mode A2; skin reuse needs nothing more).
- A loose .skin is found by name for an MD21 file without SFID, or for a legacy MD20 file (enables Mode A1).
- A loose M2 with no ModelFileData row is accepted, its header box and radius drive culling, and useMips=true gives mipmaps.
- Per-pixel depth between actors inside ONE scene (geometry interpenetration). Fact 6 only shows correct ordering. Near-certain, but not directly tested.
- Depth written by a lower scene survives UI textures drawn between scenes in the board's flattened (SetClipsChildren) frame. Fact 5 is strong indirect evidence, not a direct test. Needed by Mode B and by the floor split for marks.
- No depth clear happens between frame levels or strata inside the board.
- spells/unitcube.m2 (FDID 167145) loads and draws in game. It is present in the local 2.5.6.69795 root and was parsed offline.
- What SetAllowOverlappedModels(true) does: isolate or clear scene depth, or nothing.
- Actor yaw/pitch/roll order, and the scene's handedness relative to room data (cam.mirror), for room tiles and doodads.
- Particles in ModelScenes are depth-tested against other actors' depth.
- Frame cost of one large room M2 (about 50k triangles) and of 250-4000 paused cube actors.
- M2 material flags (unlit, two-sided), texture wrap flags and the alpha-key threshold behave in ModelScenes as in the world.

**in_game_tests:**
- 1. Loose model (decides Mode A; do a full client restart after installing the test files). `/dz 3d gputest models` shows five actors, each loaded with SetModelByPath from Interface\AddOns\DisasterZone\Media\Test\:
- (a) a byte copy of unitcube.m2 with its vertices rewritten into a 3x1x1 bar, SFID/TXID unchanged;
- (d) a byte copy of 189641 with its 1,700 pieces rearranged into a flat 10x10 checkerboard and TXID set to a WMO texture;
- (b) MD21 without SFID plus b00.skin (a pyramid);
- (c) legacy MD20 plus c00.skin;
- (e) one real room tile (Magtheridon).
For each file, chat prints C_UIFileAsset.IsLooseFile and GetFileID, the SetModelByPath return value, IsLoaded after OnModelLoaded, GetModelFileID, GetModelPath and GetActiveBoundingBox; then read Logs\Model.log.
Pass for A2: (a) shows a bar three times a stock cube's length, and (d) shows the checkerboard. A1 also needs (b) or (c) to pass.
- 2. Depth through UI (decides Mode B and the marks floor split). Run it in a frame with SetClipsChildren(true), like the board:
- scene P (low level) holds unitcube (FileID 167145) at scale 6, 20 yd away, covering half of your character;
- your character is 35 yd away in scene C (high level);
- an opaque grey texture sits at a level between them;
- both scenes use identical FOV and clips 0.5/1500.
Buttons: texture blend DISABLE / ALPHAKEY / BLEND; texture off (control: the cube is visible and cuts you); P in a lower strata.
Pass: your character has a cube-shaped hole that shows grey.
- 3. Same panel: SetAllowOverlappedModels(true) on C only, then on P only, and print GetAllowOverlappedModels on a fresh scene.
- If 'C = true' removes the hole, the flag isolates scene depth. Mode B must keep it false, and depth slicing becomes a correct fallback.
- If 'P = true' keeps the hole, set it on P so it starts from clean depth.
Also add a third scene with a big model in MEDIUM strata under the panel: does it punch holes into C?
- 4. Same panel, control: the cube and your character intersecting in ONE scene must show a straight cut line across the body (per-pixel depth within a scene).
- 5. Cost: buttons spawn 250, 1000 and 4000 paused cubes in P with the board open, and load room tile (e) alone. Print GetFramerate() and the ms per frame for each.
- 6. Alignment in the real board (only if test 1 passes). `/dz 3d native on` loads Magtheridon's room as M2 while the textured room is drawn at 50% alpha over it. Orbit, use the top view and walk inside the room. Edges must coincide within about 1 px everywhere, and no tile may vanish when its origin is behind the camera. This proves the scene-to-room transform (cam.mirror, winding, no sideways centring, culling). Add one MODD doodad with an obviously asymmetric shape as an actor next to a known wall to fix rotation order and handedness.

**build_plan:**
- 1. Pin the data source. Move the scratch local CASC reader (casc_local.py) into dev/generators, keyed to C:\World of Warcraft\.build.info (wow_anniversary). Make gen_rooms.py, m2_tools.py and wmo_tools.py read from it first and fall back to wago only for missing files. Regenerate ONE room (Magtheridon) and compare it in render_check before regenerating all of them, per the user's one-room-at-a-time rule.
- 2. Write dev/generators/m2_write.py with three parts:
- (i) a template patcher that copies a Blizzard MD21 file and rewrites vertices, normals, UVs, an x/y-symmetric header box, radius, TXID, material flags/blend and texture wrap;
- (ii) a skin-reuse packer for 189641 / skin 494450 that assigns room triangles and quads to the 1,700 free pieces and collapses the rest;
- (iii) a full writer with its own .skin and many batches for A1.
Add a strict validator that parses every file back (index ranges, bone and lookup sizes, box). Nothing unvalidated ships.
- 3. Test kit: the Media/Test files from test 1 plus one dev command, `/dz 3d gputest`, in UI/StrategyMap3D.lua next to SceneTest. It has two tabs: Loose models, and Depth through UI (with the flag and cost buttons). Delete it once the decision is made.
- 4. The user runs the session once (full restart first). Record the results in project memory and pick a mode: Mode A if test 1 passes; Mode B if test 1 fails and test 2 passes; otherwise the fallback.
- 5A. gen_rooms emits per-instance region tiles (about 64 yd) as M2 files in scene coordinates: WMO groups, terrain, MLIQ and MH2O liquids, and static doodads skinned at Stand t=0 with m2_anim. It also emits a Lua manifest per encounter (paths, tile origins, expected boxes, animated-doodad placements, the floor-face set) plus the reduced Lua collision, walk and floor-grid data.
- 6A. In View.lua, add View:LoadRoomModels(manifest): actors in the main scene (and floor tiles in P for the floor split), SetModelByPath(path, true), scale 1, verified on OnModelLoaded with a timeout. Report ready or failed, and never switch modes while files are still loading.
- 7A. Native mode in StrategyMap3D and the Trainer:
- Room.lua draws no textures but keeps FloorZ, ScreenRay, CameraDistance and walking;
- no occluders, part boxes, copies, scene0 backdrop, scene2 or slices;
- the player and Kil'jaeden go into the main scene;
- keep the old path intact as the per-room fallback.
- 8A. Marks: use the floor split if test 2 passed (P floors, then UI marks, then C everything else, plus a Lua ray check for overhangs). Otherwise draw marks above the scene with sampled ray-cast visibility, plus per-model line copies.
- 9A. Animated doodads become actors: SetModelByFileID, uniform scale, rotation using the order calibrated in test 6, centring compensation via GetActiveBoundingBox as in V:ModelCentre.
- 10A. Look and QA pass:
- scene light and ambient per room, and the water material;
- screenshot comparison against the textured view;
- ui_audit and the trainer render gate;
- wowmock support for SetModelByPath, the loose-file table and SetAllowOverlappedModels;
- user sign-off on the new look.
- 11A. Full release: a size budget (tiles shared between encounters), a changelog entry, and the room tests updated. Optionally ship the rooms as a companion addon folder (any Interface\AddOns path works).
- 5B. (Only if Mode A fails and test 2 passes.) Proxy cover generator in gen_rooms: oriented squares inside opaque faces, a 2 cm inset, side limited by thickness ray casts, and tolerance delta across convex edges. Report the cube count and the per-pixel error per room via a render_check proxy z-buffer compared with render_truth. Iterate delta until the error and count targets are met.
- 6B. View.lua sandwich:
- P = scene0 moved to parent+1 with its proxies paused and created in batches;
- an opaque backdrop at the floor level;
- room textures and marks as now;
- a single scene C for creatures, the player and doodads (from MODD/MDDF placements);
- SetAllowOverlappedModels set according to test 3.
In Room.lua, keep copies only for ALPHAKEY/BLEND pieces and for marks in front of models. Remove DISPLAY_PARTS occluders and slices, and use the freed copy budget for more room faces (measure it).


### The room as a real model: one GPU depth buffer for the room, doodads and creatures

**one_line:** Stop combining two renderers. Ship each room as M2 model files that the client draws in the same ModelScene as the creatures, so the game's own depth buffer decides every pixel. One quick in-game test settles it first: a loose, edited copy of Blizzard's unit cube.

**how_it_works:** CONTRARIAN VERDICT. None of the other ways of showing the room is better; the room has to move into the game's 3D renderer instead.
- Pre-rendered images (fixed views, finished room): orbit and walk mode are lost. Models would still need the room's depth at every pixel, and UI images cannot write depth. Worse than the other options in every respect.
- Showing the room in the game world itself: no API moves the world camera, shows an instance you are not in, or creates creatures on the client. Not possible.
- Camera limits or a Sims-style cutaway: walls would hide things less often, but nothing would become correct. At most an optional view setting.
- The consensus "sandwich" (proxy scene, then room textures, then creature scene): still two renderers that must line up to below a pixel. It relies on an untested behaviour (depth surviving the UI textures drawn between scenes). Its proxies can only approximate the room, because actors scale uniformly. Project memory says rooms are mostly organic faces, so covering about 7000 organic triangles with cubes or squares means either tens of thousands of actors or uncovered slivers. It is a fallback, not the best option.

WHAT A GRAPHICS ENGINEER WOULD DO: put everything that must be depth-sorted into ONE renderer. The only renderer with depth is the M2 renderer behind ModelScene. In-game facts 4 and 6 already show that one scene with one clip range sorts models correctly per pixel. So the room has to become M2 geometry.

DESIGN
1. Offline (dev kit). Read the room's WMO groups, ADT terrain, liquids and doodad placements (MODD/MDDF) from the installed client's own storage, pinned to build 2.5.6.69795. This replaces the unpinned wago downloads (101 of 290 WMO groups differ from the client).
   Write the visible mesh as M2 files under Interface\AddOns\DisasterZone\Rooms\<instance>\:
   - vertices with position, normal and UV, in scene coordinates (the calibrated y mirror applied, triangle winding flipped to match);
   - one static bone;
   - materials: opaque, alpha-key, or alpha-blend for liquids; two-sided where the WMO face is;
   - textures referenced by TXID to the same Blizzard WMO and terrain BLP FileDataIDs the room uses today (stable, and already in the client);
   - correct header bounds.
   The triangles go either into our own .skin file, if the client finds loose skins, or into a BORROWED Blizzard skin through SFID. A skin holds only index lists. Positions, UVs, materials and textures all live in the M2 body, which is ours.
   I checked the installed client read-only:
   - unitcube.m2 (167145, 1,922 bytes, MD21 v274, chunks MD21/TXAC/LDV1/SFID/TXID) uses skin 492738, which is 6 separate quads.
   - Skin 496338 (owned by model 193019, hellfiresupplies_01.m2) is 434 separate quads in 1 batch (shader 0, 1 texture).
   So a body that borrows skin 496338 can hold 434 arbitrary quads (868 triangles); unused quads are collapsed to a point. A room then takes about 25-150 such actors (one texture per actor); with our own skins it takes 1-3.
   Evidence: scratchpad\contrarian\skinscan.py, skins.pkl (all 14,826 skins), owners.py, cube.py.
2. In game. One ModelScene holds:
   - the room chunks: SetModelByPath, scale 1, position 0, so fact 7 (position multiplied by scale) never applies;
   - the doodads as Blizzard's own M2 actors by FileDataID (their placements use uniform scale, which SetScale matches);
   - the creatures and the walker.
   All share one camera and one clip range. The GPU depth test then decides, per pixel and in any animation frame, with no Lua work per frame:
   - room against model, and model against model;
   - doodads against everything;
   - particles against walls;
   - the water's tint over submerged body parts.
   In this mode the copies, occluder parts, slices, the second scene and the backdrop scene are removed.
3. Lua keeps only the work that is not drawing:
   - collision and walk faces (already in the room files);
   - mouse picking, using the collision mesh plus Project3DPointTo2D as the projection reference;
   - UI overlays, drawn above the scene as now ("drawings always show over models"), with their hidden parts dimmed by ray tests. Rings could instead be small M2 files, which gives them exact depth.
4. Safety.
   - When a room opens, a tiny probe M2 is loaded first, and GetActiveBoundingBox must match the shipped bounds (only our file body can give those).
   - A saved crash-guard flag is set before loading and cleared after. If it is still set at login, or the probe check fails, the board falls back to today's renderer automatically.
   - The executable's strings show that the M2 loader checks array bounds ('M2Init M2Array failure ...', 'Corrupted model', fallback 'ErrorCube'), so a bad file most likely shows an error cube rather than crashing. Files are also validated offline.

**accuracy:** EXACT PER PIXEL, by construction, wherever both surfaces write depth:
- opaque and alpha-key room faces (alpha-key is decided per texel, exactly as in the game);
- doodads;
- creatures in any animation frame, without the pose or timing problem the copies method has;
- your character with its real gear;
- particles, which are depth-tested against the room. Clipping and copies could never handle particles.
This is the same depth test the game itself uses. With a 24-bit buffer and near/far 0.5/500, depth resolution is about 1 mm at 100 yd. Coplanar surfaces flicker only where they would in the game. The geometry is the client's own, read from the installed build, so there is no proxy-fit error at all. That is the key difference from the sandwich, whose accuracy is only as good as the cube or square tiling.

NOT EXACT:
(a) Two transparent surfaces (the water surface against a glow or a ghost) are ordered by the M2 renderer's per-object sort, as in the game.
(b) Appearance, not depth:
- WMO baked vertex colours and WMO shaders become per-batch colour buckets, or scene lighting with the WMO normals;
- blending between ADT terrain texture layers is approximated (dominant layer per chunk) unless loose BLPs load by file name inside M2s.
(c) Model placement errors (for example the Lurker standing several yards off his circle) are a separate problem and stay as they are.
(d) Drawings and labels stay on top of the scene by design. They do not hide behind pillars unless they are made into M2 files.

Everywhere else the error is zero. If the decisive test fails, accuracy falls back to the fallback's:
- sandwich: limited by the proxy fit;
- improved copies: 0.05-0.28% of model pixels wrong (measured offline), particles never correct.

**looks_complete:** Yes, and that may matter more than the depth fix.
- The 7000-face / 2990-node budget exists only because Lua paints the room. The GPU draws 100k+ triangles in one scene; Blizzard's glue-screen environments are single M2s of 14-18k vertices spanning about 385 yd. So whole WMO groups ship, with no cropping holes.
- The missing props come back as Blizzard's own animated M2s. Black Temple alone has 3,520 placements of 264 models, including the animated boss-room water (191471).
- Liquids become see-through meshes that can move, using M2 texture transforms for scrolling UVs.
- Textures become perspective-correct, filtered and mipmapped, with no affine wobble and no seams between 1x1 textures.
- Rebuilding from the installed client also brings back the about 9% of triangles lost to mismatched wago downloads.

Remaining gaps:
- baked WMO lighting is approximated;
- there is no sky (fog or a backdrop colour instead);
- ADT terrain texture blending is simplified unless the optional loose-BLP test passes.

The Raid Trainer gets the same benefits, and about 6 ms of Lua per moving frame goes away.

**fallback:** If cube_a does not load as the L shape, the loader rejects loose models and no custom geometry can reach the GPU.
(1) Use the depth pre-pass sandwich with Blizzard's own primitives, but only if T1 passes. The order is: a proxy scene at lv.floor using the same camera and clips (unitcube 167145, world/scale cubes, the one-sided 1.389 yd square 2199509, the slab 200293), then an opaque backdrop, then today's room textures, then one scene for creatures and doodads. Measure the proxy error and actor count per room offline with render_check before shipping; organic rooms may not reach good accuracy at an affordable actor count. Keep copies for alpha-key and blended room pieces.
(2) If T1 also fails, keep today's copies, but build occluders from the true pose as per-bone convex hulls, and freeze the animation so the copies match the pose (SetAnimation(anim, 0, 0, t) or actor SetPaused). Measured offline: 0.05-0.28% of model pixels wrong against 3-10% today. Particles are never handled.
In every branch:
- rebuild rooms from the installed client;
- add doodads as Blizzard's own actors by FileDataID (proven loadable in the trainer); in copies mode they need static exact occluders against the room;
- keep the current renderer as the safe default until the user approves a room.

**reliability_risks:**
- Loading a loose model from an addon folder is undocumented, and a later client patch could block it. Mitigation: the bounds-signature probe at every room open, an automatic fallback to the current renderer, and Room.lua kept working.
- If our own skins fail and a Blizzard skin is borrowed: should Blizzard re-export skin 496338 in a patch, bodies built for it would draw garbage or an error cube. Mitigation: prefer our own skins. If borrowing, record the build it was checked on (GetBuildInfo) and the skin's index count, re-check with the dev kit for each new build, and keep an allow-list that a Lua hot patch can switch.
- A malformed M2 could crash the client instead of raising a Lua error. The loader appears to check bounds (exe strings), but WoWUIBugs #67 shows some bad loads do crash. Mitigation: a strict writer, an independent offline validator that mirrors the 'M2Array failure' checks, starting from byte-identical files, and a crash-guard flag in saved variables.
- Loose files get negative FileDataIDs that shift between sessions. Never store them; always load by path.
- New binary files need a client restart (or /reload) and a full release. They cannot be hot-patched.
- Size: M2 vertices take 48 bytes, uncompressed. Shipping each WMO group once per instance with our own skins is roughly 50 MB; borrowed skins are about 3x that. Move the rooms into a LoadOnDemand companion addon. Files on disk cost nothing until shown, unlike today's 12 MB of Lua strings loaded at login.
- Performance of 25-150 room chunks plus hundreds of doodad actors in one ModelScene has not been measured.
- Visual parity: the room will look different from today's textured version (lighting). Following the user's rule, change one room at a time and compare against a rendered image.
- Calibration: the scene's y mirror and winding have to be applied when the files are generated, and the doodads' yaw/pitch/roll order and pitch sign must be measured.
- UI overlays lose their BSP ordering and draw on top by design. Rings that need exact depth must become M2 files.
- Unknown whether addon hosting sites accept .m2 files in addon zips. This does not affect the guild's own release channel.

**depends_on_unverified:**
- A loose .m2 under Interface\AddOns loads with SetModelByPath (or with C_UIFileAsset.GetFileID's negative ID through SetModelByFileID) and draws its OWN vertex data. This is the key assumption.
- A loose model file's SFID that points at a Blizzard skin is honoured (borrowed skin). Alternatively, loose skins are found by file name for an MD21 file without SFID, or for an MD20 file.
- The loader accepts a model with no ModelFileData row (LOD count, GeoBox).
- TXID references to WMO and terrain BLP FileDataIDs show correctly in M2 materials (opaque, alpha-key, alpha-blend), and texture-transform UV scrolling works for water.
- Very large models (100-200 yd) with correct header bounds are not wrongly culled in a UI ModelScene.
- Frame cost of tens to hundreds of static actors in one scene.
- Doodad rotation order and pitch sign, and how the scene's y mirror affects handedness for M2 geometry.
- Optional: loose BLPs referenced by file name in M2 texture slots, needed for baked lightmaps and terrain layer blending.
- Fallback only: depth written by a lower ModelScene survives the UI textures drawn between it and a higher scene (T1).

**in_game_tests:**
- DECISIVE, one restart, about 5 minutes. A dev script writes Media\Probe\cube_a.m2 from the installed client's own bytes: unitcube.m2 (167145) unchanged, except its 24 vertex positions are moved into an asymmetric 'L' (one quad pulled 2 yd out along +x, the top quad lifted 1 yd and tilted) and the header bounds are updated. Its SFID (492738) and TXID (167204) stay as they are. After a full client restart, a probe command shows one ModelScene with the stock 167145 cube as the control next to cube_a. For each file it prints C_UIFileAsset.IsLooseFile and GetFileID, the success value of SetModelByPath, IsLoaded after the load callback, GetModelFileID and GetActiveBoundingBox; then check Logs\Model.log. PASS: the L shape is visible (loose model bodies load and the borrowed skin works, so arbitrary geometry is possible). FAIL: a plain cube, an error cube or nothing while IsLooseFile is true, meaning the loader rejects loose models; go to the fallback. The L's direction also checks handedness under the scene's mirror.
- Same session, no extra restart: (a) cube_c.m2 = cube_a without the SFID chunk, plus cube_c00.skin; (b) cube_b.m2 = the same model as a non-chunked MD20 file, plus cube_b00.skin. If either shows, we can ship our own skins (1-3 actors per room, about 3x smaller files). (c) soup.m2: a body that borrows skin 496338 and carries about 40 triangles of Magtheridon's floor and one pillar, with TXID set to that room's WMO texture, and Brutallus placed through the pillar. This should show the room texture and a straight per-pixel cut where the pillar and Brutallus meet.
- Same session, so the fallback decision is ready: the T1 sandwich. Scene A holds stock cube 167145 at scale 6, 20 yd away; an opaque full-frame texture sits on a middle level; scene B holds a creature 35 yd away directly behind; both scenes use the same clips. Run it in a plain frame and inside a SetClipsChildren frame. PASS: the creature has a cube-shaped hole showing the grey.
- Only after a pass: about 100 soup actors (about 87k triangles) plus 10 bosses while orbiting. Read GetFramerate and debugprofilestop times. Also calibrate doodad rotation: one asymmetric doodad at yaw/pitch/roll 30/20/10 degrees, compared with Project3DPointTo2D markers at its expected corners.

**build_plan:**
- 0. Run the probe. A small dev script builds the probe files from the installed client's storage (the scratch reader at scratch_wago\casc\localcasc.py already works read-only) and adds a throwaway '/dz 3d probe' command. Decide the route from the results.
- 1. Add a pinned local-storage reader to the dev kit (dev/generators/casc_local.py) and make gen_rooms.py and m2_tools.py read the installed build instead of unpinned wago downloads.
- 2. dev/generators/m2_writer.py: an MD21 v274 writer covering the header, 48-byte vertices, one static bone, bone lookup, materials (blend mode and flags 0x1/0x4), texture table with TXID, texture lookup, colours, texture transforms for water, bounds, SFID and LDV1. It also writes our own .skin if test 2 passes; otherwise it packs triangles into the 434-quad borrowed skin 496338. Add an independent validator (re-parse, all bounds and index checks) and offline QA images via render_check's depth buffer.
- 3. gen_rooms.py output for each room: room chunks (whole WMO groups shipped once per instance, plus terrain inside a generous box, with no face budget) split by texture, blend mode and light bucket; liquids as alpha-blend batches; a Lua manifest (chunk paths, bounds signature, light colours); doodad placements (fdid, position, quaternion converted to the calibrated yaw/pitch/roll, scale); and the collision/walk data unchanged.
- 4. Render3D/GpuRoom.lua: loads the chunks and doodads into the view's ModelScene (scale 1 for chunks), checks the probe's bounds signature, sets and clears the crash guard, frees models with ClearModel on close, and sets per-room scene light and fog.
- 5. View.lua and StrategyMap3D.lua: a 'gpu' mode with one scene for room, doodads, creatures and walker. Occluders, copies, slices, the second scene and the backdrop scene are switched off. Overlays draw above the scene, with hidden parts dimmed by Lua ray tests against the collision mesh. Picking uses the collision mesh, with the projection checked against Project3DPointTo2D. The trainer gets the same mode.
- 6. Roll out one room at a time (the user's rule): render it offline, compare it with today's room and the map, then show it in game. Keep '/dz 3d renderer ui' as the manual and automatic fallback.
- 7. Ship as a full release; consider a LoadOnDemand 'DisasterZone_Rooms' companion addon for the binary rooms. Correct the notes this proves wrong (findings.md:89, View.lua:266-268), and record the result in memory and the changelog.


### Exact scanline copies against frozen true meshes ("ESC"): all depth decided in Lua, per pixel, using the models' real triangles

**one_line:** Freeze each creature at a pose whose exact mesh is extracted offline from the local client. Put all models in one ModelScene. In Lua, repaint each room piece over the models exactly where it is nearer than the visible model surface, computed per physical pixel row from the real triangles. This relies on no unverified depth-buffer behaviour. A prototype reproduced a z-buffer with 0 wrong pixels out of 17.0M.

**how_it_works:** What stays the same:
- The room is still the BSP-painted textures under one ModelScene.
- Room pieces are still drawn again over the scene ("copies").

What changes is what gets copied: the exact region, worked out from the models' true triangles, instead of part boxes, planes and slices.

1) Known geometry.
- Each creature is frozen at a pose the addon knows: actor:SetAnimation(0, 0, 0, 0), which is how Blizzard freezes models in ModelSceneMixin. The alternative is SetPaused after load.
- Offline, the generator reads that exact pose from the user's own local CASC (build 2.5.6.69795):
  - LOD0 skin. The offline survey found exactly one skin LOD for all 141 board displays, so there is no LOD switching.
  - Skinned Stand at t=0. That is the first keyframe of every track, so interpolation conventions don't matter.
  - The client's geoset choice.
  - Only depth-writing batches (opaque and alpha-key; blend <= 1 and no flag 0x10).
  - A per-triangle cull flag (0x4 two-sided).
  - The mesh's convex hull.
- It ships quantised and deflated per display, loaded per encounter.

2) One scene. All models go in one ModelScene with one clip range, so the GPU sorts them among themselves (verified, facts 4-6). The walker moves into it from scene2. The backdrop scene, slices and part boxes are retired. One global copy stack sits above the scene, in room order.

3) The rule, at pixel P: draw room piece R again at P if and only if:
- P is covered by a drawn model triangle, and
- no drawn model triangle covering P is nearer than R.

At P the copies are then exactly the room surfaces nearer than the visible model surface. Painted in BSP order, the nearest one ends on top, which is the z-buffer composite. Nothing is copied off the model.

4) Lua, per camera move or model move only (a still view costs 0 ms):
- a. Project the model vertices, clipping triangles at the scene's near clip. Set up each triangle with 1/z = A x + B y + C. Bin triangles into 16 px tiles, keeping each tile's farthest model point (min 1/z).
- b. Classify every GPU triangle of every drawn room piece against the hull, using R's plane. This is camera-independent per placement; only the eye's side flips.
  - Model entirely in front of R: skip.
  - Model entirely behind R: copy wherever the model covers.
  - Straddling: exact test.
- c. Per tile, drop R wherever max over the tile corners of 1/z_R is below the tile's min model 1/z.
- d. For each live (R, tile row), and each physical-pixel row in it:
  - Take the model spans, sorted by x.
  - Copy = union of the spans ∩ R's span, minus the sub-interval of each span where that triangle's 1/z is at least R's. That is one linear comparison per span, so every interval end is analytic.
- e. Consecutive rows whose ends lie on the same two screen lines merge into one trapezoid. The line is a model edge, an R edge, or a model/R depth-crossing line. Each trapezoid is ONE copy texture: the piece's own texture, with its own affine UVs (as Room.lua's Fan does). It goes into the copy stack at the piece's room-order place. Mark lines are treated as thin pieces.
- Rows are taken in physical pixels (UI units × effective scale × physical/768). That makes pixel-centre sampling match the GPU's coverage rule.

5) Prototype (read-only scratch, not the addon), run in PUC Lua 5.1 through lupa:
- C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\aa52e4d4-c087-4769-a09e-98ce81f5d755\scratchpad\esd.lua (Run), esd2.lua (Run2, tiles), esd3.lua (Run3, per-placement hull sides)
- Harness: esd_export.py (system python: real posed mesh from local CASC, shipped room, numpy z-buffer truth) and esd_bench.py (run with dev\luaenv python).
- Results: esd_b3_brutallus.txt, esd_b3_lurker.txt, esd_b3_mag.txt, esd_b3_lurker1350.txt.

Results:

| Boss | Views | Model pixels | Wrong pixels | Copy textures (median / max) | ms per camera move (median / max) |
|---|---|---|---|---|---|
| Brutallus | 24 at 900×600 | 3,542,137 | 0 | 10 / 55 | 17 / 34 |
| Lurker | 24 at 900×600 | 3,460,965 (687,777 truly hidden) | 0 | 69 / 283 | 15.5 / 44 |
| Magtheridon | 24 at 900×600 | 2,180,652 | 0 | 20 / 35 | 20 / 42 |
| Lurker | 24 at 1350×900 | 7,786,991 | 0 | 76 / 297 | 19 / 62 |

- The comparison is against an exact z-buffer of the same mesh in the shipped rooms.
- Copy textures stay well inside COPY_TEX_MAX 1500. They grow with geometry, not resolution.
- Timings are for an unoptimised prototype that allocates per call. Three benchmarks ran in parallel; os.clock has 1 ms resolution.

**accuracy:** Verified offline: the algorithm is pixel-exact against the given mesh. In 96 views of three bosses in the shipped rooms, it matched a numpy z-buffer at pixel centres with 0 missed and 0 extra pixels out of 16,970,745 model pixels.

Exact in game, at pixel-centre sampling, IF the fit test passes, for:
- Every room surface the renderer actually draws, of any shape: terrain, curved or acute walls, stairs, water, mark lines, ALPHAKEY railings and BLEND pieces. A copy re-draws the identical piece with the identical texture, UVs and alpha test, so cut-outs and translucency stay correct. This is better than cube proxies, which are exact only on box-like planar solids and need copies anyway for alpha/blend pieces.
- Every depth-writing triangle of models whose frozen mesh is known: bosses and adds at Stand frame 0.
- Model vs model is exact, because the GPU sorts within one scene.

Sub-pixel caveat: with MSAA, the samples inside the few rows where a vertex or edge switch falls can differ, so expect ≤1 px fringes there. The angled sides of a trapezoid follow the true lines, so silhouette edges match sample for sample.

NOT exact:
- **Particles.** They can't be known in Lua; glows behind walls show through as today. SetParticleOverrideScale(0) might hide them; untested.
- **Blended effect triangles** (no depth write; e.g. Kil'jaeden's 3,956). Where an effect is in front of a wall and the body is behind it, one of the two is wrong; they are included in the occluder set.
- **Alpha-key model cut-out texels** are treated as solid. A deeper model part can show over a wall inside a hole. Counts: Brutallus 24 triangles, Lurker 192, Kil'jaeden 1,043.
- **Animated poses.** The offline study found a 1-frame lag means 1.2% wrong pixels on the Lurker, and a random phase 16%. So exactness requires frozen poses, or Lua-clocked offsets if verified.
- **The player and party (SetModelByUnit, live gear, live run cycle).** Only approximated, by per-bone hulls of the race base model plus a gear margin, so there is an error band of a few cm. They would be exact only with fixed creature-display stand-ins.
- **Any display whose placement, geosets or pose fails the fit test.** The board's own notes (DISPLAY_CENTRE, the Lurker's offset from his ring) show placement is not yet proven for every model.
- **Room drawing.** Occlusion is exact relative to what the room renderer draws. The room itself remains affine-textured (tau 1.5-5 px texture swim, unchanged) and cropped.

**looks_complete:** Only partly; the method is about depth, not completeness, but it combines well with completeness work and makes some of it exact for free.

1) **Rebuild rooms from the local CASC instead of unpinned wago downloads.** 101 of 290 WMO groups differ, and the downloaded copies have about 9% fewer triangles; this fixes those holes.

2) **Bake static WMO doodads into the room mesh** as textured, BSP-sorted triangles: MODD/MODS/MODN in WMO roots, MDDF in ADT obj files. Black Temple alone has 3,520 placements of 264 M2s. They then occlude and are occluded exactly (painter for room vs doodad, copies for doodad vs model), with no per-frame cost beyond room pieces.

3) **Animated doodads** become frozen actors in the scene with their meshes in the occluder set. Examples: bt_sewerwater_bossroom.m2 (191471), banners.

4) **Liquids.** Add MLIQ/MH2O as room pieces.

The limit is honest: the face budget (MAX_TRIS 7000 / MAX_NODES 2990) is a Lua-time and frame-level budget. This approach spends more Lua time (15-20 ms per camera move near a big boss), not less, and baked doodads raise face counts. Fully complete rooms therefore also need room LOD/culling and engine optimisation. Unlike the GPU-proxy route, this method frees no Lua budget.

**fallback:** If the fit test fails for a display (pose, geosets or placement not reproducible) or the Lua cost is too high, keep the same engine and Σ rule but give it per-bone convex hulls instead of the true mesh. Use hulls of the frozen pose, or of the whole Stand cycle when the animation can't be frozen. Offline, per-bone hulls measured 0.05-0.28% wrong pixels against 3.0-10.35% for today's part boxes. The cost is lower (27-91 parts of about 16 faces each instead of thousands of triangles), and it is still free of any unverified depth-buffer behaviour. The last resort is today's box copies.

Where in-game test T1 passes (scene depth survives UI textures), a hybrid is possible:
- GPU cube proxies for box-like architecture, which also handle particles, effects and real-gear players exactly.
- These Lua exact copies for terrain, curved, acute, alpha-key and blended room surfaces, where proxies can't be exact.

Each method covers the other's weak side.

**reliability_risks:**
- Lua CPU while the camera moves. The prototype measured 15-20 ms median and 34-62 ms worst per camera move per big boss, in PUC Lua via lupa. WoW's Lua speed relative to lupa is unmeasured (expect ±2x). Several bosses or adds add up. Mitigations: preallocated buffers (the prototype allocates per call), incremental edge stepping, a per-row visible envelope, temporal reuse, a ms budget with per-bone-hull copies while dragging and exact copies once the camera rests. A still view costs 0.
- Silent pose or placement mismatch for some displays: wrong geoset choice, the DISPLAY_CENTRE quirk, a lopsided GeoBox, a mirrored y, a model with billboarded bones. Every display needs to pass the fit test. A generator-side table of verified displays, plus a fallback to hulls for unverified ones, keeps the failures visible instead of silent.
- Dependence on the exact client build. The meshes must be regenerated when Blizzard patches model files. Mitigation: store the build number with the data and fall back to hulls on a mismatch.
- Data size. Exact frozen meshes for about 141 displays come to roughly 3 MB compressed (398k triangles total, fewer after dropping non-depth-writing batches). Load per encounter; decoding costs time at room open.
- Frozen bosses lose their idle animation. This is a UX trade-off, unless the optional Lua-clocked animation test passes. Lua skinning (about 3-8 ms per boss per frame, an estimate) plus per-frame exact copies would then make one animated boss affordable, but not a whole Trainer wave.
- Physical-pixel mapping. UI scale, effective scale and pixel snapping must be handled exactly. Copies already use SetSnapToPixelGrid(false) and SetTexelSnappingBias(0). Rows computed in the wrong space turn exact into sub-pixel-approximate.
- Model triangles crossing the near clip (camera inside a big boss) must be clipped at exactly the scene's 0.5 yd near plane. The prototype only skipped such triangles, because its views were 25-45 yd away.
- Copy-stack capacity. All models share one room-ordered copy stack in frame levels copy0..plates. Lurker peaks were 283 textures and about 110 distinct pieces, which fits, but crowded multi-boss scenes need a cap and a defined degrade order.
- The player, party and real-gear NPCs remain approximations. 41 of the 141 board displays are character models with gear; making those exact needs offline item and geoset resolution.

**depends_on_unverified:**
- actor:SetAnimation(0, 0, 0, 0) (or actor:SetPaused(true) after load, new in 2.5.6) freezes the model at exactly Stand frame 0. That is the same pose the offline skinning produces. Blizzard uses SetAnimation(0,0,0,0) for frozen previews, but it has not been observed for these creatures.
- The client's submesh/geoset selection for each creature display equals the offline extractor's choice. The single LOD per model is verified offline; the geosets are not.
- The model placement convention is exact for every display: origin at the actor position with SetUseCenterForOrigin(false,false,false), position divided by scale, SetYaw with cam.mirror, uniform scale. Facts 7-8 support it, but the Lurker/Kil'jaeden centring history shows it is not proven per display.
- M2 batch semantics as reimplemented by viewers: two-sided 0x4, no depth write 0x10, AlphaKey writes depth. These decide which triangles count as occluders and whether to cull back faces.
- The UI-unit to physical-pixel mapping used for the rows matches what the client rasterises.
- WoW's Lua runs this code at a speed comparable to stock PUC Lua 5.1 (the lupa measurements).
- Optional only: animOffsetSeconds with animSpeed 0 shows the pose at that offset, for Lua-clocked animation; SetParticleOverrideScale(0) hides particles.
- Explicitly NOT depended on: the shared depth buffer between scenes, depth surviving UI textures (T1), SetAllowOverlappedModels, SetIsFrameBuffer, OffScreenFrame, or loading custom M2s. Within-scene model sorting (facts 4-6) and copies drawn over the scene are already verified.

**in_game_tests:**
- THE decisive test: the fit test, /dz 3d fittest <display>. It checks pose, skinning, geosets, placement, mirror and projection at once. Ship the frozen offline mesh for Brutallus 22711, Lurker 20216, Magtheridon 18527 and one character-model NPC (e.g. 18239). The test places each model with the board's own DrawModels placement, freezes it (variant A: SetAnimation(0,0,0,0); variant B: SetPaused(true) after OnModelLoaded) and hides the room. It then paints the offline silhouette above the scene as solid-colour trapezoids, using the same row engine. OUTSET mode grows the fill by 1 px and must hide the model completely. INSET mode shrinks it by 1 px and must leave an unbroken 1-px rim all round. Orbit through 6 yaws × 2 pitches and take screenshots (or call Screenshot() and diff offline). Pass = no model pixel outside the outset fill and a complete rim in inset at every angle. Any offset, wrong geoset or wrong pose shows as a crescent or a missing limb.
- Same session, optional: SetAnimation(0, 0, 0, 1.0) against the offline mesh at t = 1.0 s. If it fits, Lua-clocked idle animation is possible.
- Same session, optional: actor:SetParticleOverrideScale(0) on Brutallus. Do the glows disappear without anything else changing?
- Same session, optional: time the Lua row engine with debugprofilestop() on the Brutallus and Lurker boards while orbiting, to compare real-client ms with the lupa numbers (15-20 ms median).

**build_plan:**
- 0. Before any engine work, build the fit-test kit. Offline: a local-CASC exporter based on the scratch casc_local.py / m2_anim.py. It reads LOD0 skin batches with materials (blend mode, flags 0x4/0x10), applies the client's creature geoset rules and skins Stand at t=0. It writes a compact mesh for 4 test displays. Lua: a minimal row-span silhouette fill with SetColorTexture trapezoids, plus /dz 3d fittest. Run the in-game test and continue only per display that passes.
- 1. Offline data pipeline in dev/generators:
- Move all extraction (rooms and models) from unpinned wago downloads to the local CASC, keyed to the build number.
- Per board/Trainer display: frozen posed mesh of depth-writing triangles with cull flags, convex hull, and per-bone hulls (fallback).
- Quantise to about 1/1024 model unit, deflate, encode as the rooms already are, and load per encounter.
- For player/party: per-race/gender base-model per-bone hulls plus a gear margin.
- 2. Offline validation harness: extend tools/render_check.py (render_truth z-buffer, line 570) and the lupa mock. Run the production Lua engine for every room × display × a view grid, and gate CI on 0 wrong pixels. The scratch esd_bench.py shows the method. Also run a performance suite that reports ms and copy-texture counts per room.
- 3. Production engine Render3D/Exact.lua, in the Room.lua style (flat preallocated arrays, no per-frame allocation):
- Model projection with exact near-plane clipping of model triangles.
- 16 px tile binning with each tile's min 1/z.
- Hull-side table per placement for every room plane, computed when a model is placed or moved.
- Tile culling, then per-tile-row span lists in physical pixels with incremental edge stepping.
- Union minus the near intervals; trapezoid merging keyed by line ids.
- Emission with the piece's affine UVs (the TA/Fan maths already in Room.lua InstallCopies).
- Mark lines as thin pieces.
- Dirty tracking: rerun only on camera or model change.
- 4. Integration:
- Move every model, including the walker, into the single scene. Delete DISPLAY_PARTS occluders, Room.SetOccluders slots, the copy restriction regions, depth slices (View.lua slice scenes and SL) and the scene0 backdrop.
- Build one global copy stack ordered by room rank in levels copy0..plates.
- Freeze bosses with SetAnimation(0,0,0,0) (or SetPaused). Board models, walker and party have no exact mesh, so they go into the occluder set as hull meshes, flagged as approximate.
- 5. Time budget:
- Optimise the engine (per-row visible envelope, temporal reuse, coarse-to-fine tiles).
- Add a per-frame ms budget: while the camera is being dragged past the budget, use the same engine with per-bone hulls (offline-measured 0.05-0.28% wrong pixels); refine to exact at rest.
- Measure in game with debugprofilestop.
- 6. Completeness, in parallel:
- Rebuild every room from the local CASC.
- Parse WMO MODD/MODS/MODN and ADT MDDF; bake static doodads into room meshes as textured BSP faces.
- Add MLIQ/MH2O liquids as room pieces; make animated doodads frozen actors with meshes in the occluder set.
- Revisit MAX_TRIS / MAX_NODES with room LOD once the engine's measured cost is known.
- 7. Optional, only if test 2 passes: Lua-clocked idle animation. Ship the Stand bone tracks, skin in Lua per frame (or at 10-15 Hz), call SetAnimation(anim, 0, 0, t) with SetAnimationBlendOperation(0), and run the exact copies each animated frame. Start with one boss and measure.


### Layered depth sandwich: the room's depth first in a hidden ModelScene, one model scene on top, Lua copies only for what is left

**one_line:** Put the room's own depth into the shared model depth buffer before any model draws, then cover it and paint today's room over it. The room's depth is either an exact custom-M2 copy of the room mesh (if loose M2 files load) or stock primitive models placed offline. Every creature, player and doodad then draws in one ModelScene with the same camera and clip range, so the GPU decides room-against-model for each pixel. Lua copies remain only for see-through alpha-keyed screens and for raised mark lines.

**how_it_works:** CORE. Facts 4-6 show that ModelScenes with identical near/far share one depth buffer and test against each other. UI textures cannot write depth. So the room's depth has to come from M2 geometry drawn in a ModelScene before the models, and then be painted over. Everything below lives inside the board's clip frame: one strata, the same rect, FOV 1.1, near 0.5, far 1500. The same camera is written to every scene in the same OnUpdate. SetAllowOverlappedModels stays false.

LAYER STACK, bottom to top:
- L0, depth scene (lowest level, paused): the room's depth (sources below).
- L1, cover: one opaque full-view texture in today's background colour. It hides L0's colours.
- L2, the software room exactly as today: BSP painter order, cluster frames, floor marks placed in that order.
- L3, ONE model scene holding every creature, your walker, the remote walkers and the room's own M2 doodads. The doodads come from WMO MODS/MODD and ADT MDDF placements, loaded with SetModelByFileID; Black Temple's root alone has 3,520 placements of 270 M2s. Every model pixel (opaque, alpha-key, transparent batches, particles) is depth-tested against L0 and against the other models.
- L4, residual copies: the existing Room.lua copy code, fed only flagged pieces (a per-prim flag checked in CopyLeaves): (a) free-standing alpha-key screens that have no proxy, (b) mark segments raised above the floor (posts, beams) that are in front of a model, with today's part boxes as occluders.
- L5, plates and HUD.

WHY IT IS RIGHT. A model pixel is drawn only if its depth is less than L0's depth. The room's colour underneath comes from L2. Floor marks become exact for free: a model pixel over a floor mark is either nearer than that floor point (it covers the mark, which is right) or behind or under the floor (L0 rejects it and the mark shows, which is right).

The following go away:
- DISPLAY_PARTS occluder boxes for room occlusion
- almost all copies
- the Kil'jaeden BACKDROP scene
- depth slicing
- the animation-phase problem: the GPU uses the live pose; offline, a phase error alone gave 1-16% wrong pixels on the Lurker.

L0 SOURCE A, custom M2 (if loose M2s load):
- gen writes the room's drawn triangles to 1-4 loose .m2/.skin files (at most 65k vertices per skin) and loads them with SetModelByPath.
- Opaque faces use an Opaque material. Alpha-key faces use AlphaKey with their real texture FDID (via TXID) and the same UVs, so the holes match per texel.
- The result is exact by construction and needs only 1-4 actors.
- Fallback A′, if loose bodies load but custom skins do not: our own body (vertices, bones, materials, TXID) plus a borrowed game skin whose triangles are vertex-disjoint. A scan for such a skin is still to do.
- Upgrade A-full: draw the floors visibly in L0 (no cover) and walls, pillars and props in L3, with the marks (UI) between them. That removes the face budget and gives perspective-correct textures and optional translucent water.

L0 SOURCE B, stock primitives. I verified these in the local 2.5.6 client: all static (no animation keys), not billboards, opaque, depth-writing, and listed in ModelFileData.
- 191087: a flat one-sided square, 1.665 yd (7x7 grid, 72 triangles).
- 202326: a one-sided unlit/unfogged triangle, 45.5/67.2/67.4 degrees.
- 202325: a two-sided triangle.
- 167145: the unit cube.
- 1067658 / 1396283: one-sided rectangles that use filename textures.
- Not usable: the "invisibletrap" squares 2199509/2199319 are spherical billboards (bone flag 0x8).
- No small stock M2 (under 8 KB) has a blended material that still writes depth, so no stock "invisible depth writer" exists.

How gen_proxies places them:
- just behind opaque faces (1-2 cm inset);
- extending past an edge only into space hidden from every camera (concave edges, inside walls);
- walls may sink up to the wall's thickness, so one big square can sit behind a decorated wall;
- terrain uses planes sunk by at most 5-10 cm;
- the 6-60 liquid triangles per water room are flat rectangles at one level, so they take exact squares;
- walkable alpha-key surfaces (Opera stage: 95% walkable, no backing) count as opaque;
- free-standing screens (Sunwell, BT: 0-1% have an opaque backing within 0.5 yd) go to L4.

Proxies are kept only where they are relevant: room faces that are ever the first thing hit between a sampled camera and reachable model space (above walkable floors, inside liquids).

Runtime: a pool of actors. On each camera move, a BVH query shows only the proxies inside some model's view frustum slice. Extra proxies are harmless, so culling is purely a cost tool.

OFFLINE SAFETY GATE for B (render_check, all 55 rooms, dense orbit and walk camera sweep). A proxy that is never nearer than the drawn room (proxy depth ≥ room depth at every pixel of every view, with 1-px edge erosion) can never hide a model wrongly. Any violation shrinks the proxy, and nothing ships until the gate reads 0. Coverage is reported with the true skinned boss meshes (m2_anim.py) plus capsule probes over the floors.

Evidence scripts (read-only, local CASC): C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\aa52e4d4-c087-4769-a09e-98ce81f5d755\scratchpad\hy\ (m2inspect.py, shape.py, primscan.py, blendscan2.py, roomstats.py, alphacheck.py, akback.py, squarecover2.py, modd.py).

**accuracy:** PER-PIXEL EXACT IN EVERY VARIANT:
- Model against model, including doodads, particles and transparent batches: the GPU with identical clips (facts 4 and 6).
- Floor marks against models: shown above in WHY IT IS RIGHT.

VARIANT A (custom depth mesh):
- Room against model is exact wherever the GPU draws, including alpha-key texels.
- One residual: today's software room draws its own silhouette, which can differ from the GPU's rasterisation of the same triangle. The Room.lua projection self-check bound is 1.5 px (usually under a pixel). That can leave a seam of about 1 px at room edges over models.
- A-full removes that seam, because the GPU then draws both the room and the models.

VARIANT B (stock primitives) is exact wherever the cover reaches on flat opaque faces and liquids. A model can wrongly show through only:
- (i) by the 1-2 cm inset;
- (ii) by the terrain sink (5-10 cm);
- (iii) at slivers in convex corners sharper than the triangle fan or squares can reach (measured per room);
- (iv) along about 2 cm of inset at convex edges, kept for the 1.5-px agreement.

Wrong hiding (cut-outs) is 0 on every sampled view by the gate, but that is not proven between samples. Free-standing alpha-key screens keep today's part-box error class, but only on those faces: Kil'jaeden 20.6%, Eredar Twins 15.2%, Teron 16.8%, M'uru 13.7% and Kalecgos 9.5% of room area are alpha-key, and 2.1-8.5% of the room area is actually see-through.

ALL VARIANTS: raised marks against models stay approximate (part boxes).

BASELINE TODAY (offline study): 10.35% of Brutallus' pixels, 3.0-3.5% of the Lurker's and 0.07% of Magtheridon's are wrong, nearly all wrongly hidden.

HONEST COST FINDING FOR B (my measurements):
- Exact-plane patches per room: mean 1,445, max 2,526.
- A naive greedy square cover with no overshoot needs 45k-55k squares for 99.9% of Kil'jaeden's and Magtheridon's area, and 170k for the Lurker's.
- So B only works with relevance filtering, overshoot into hidden space and generous sinking. Its real count must come from the generator before B is committed to.

**looks_complete:** Partly with B, fully only with A-full.
- Doodads: yes in every variant. They are stock M2 actors in L3 (all in the local client), occluded correctly in both directions through L0 and the shared depth. Doodad collision for the walker would be a follow-up.
- Face budget and holes (MAX_TRIS 7000 / MAX_NODES 2990, a renderer limit): B does not lift it. It only frees the copy frame levels and Lua time, so the budget could rise somewhat. A-full removes the budget entirely: the room becomes GPU geometry with no per-frame Lua.
- Independent of the variant, gen_rooms should read the user's own install (local CASC) instead of unpinned wago downloads. The offline study found 101 of 290 WMO groups differ, with about 9% fewer triangles in the downloads. The Black Temple root also differs.
- ADT MH2O liquids are still to add.
- Water can stay opaque (exact with either L0 source) or become translucent in A-full.

**fallback:** The fallback depends on what the depth lab shows:

- **T1 fails but a loose M2 loads:** put the room as native geometry in L3 itself (A-full with nothing between scenes). Draw marks above L3 and clip them in Lua: exactly against the room through the BSP, approximately against models with boxes. If variant D passes, an invisible custom depth mesh directly under L3 also works, and it does not need T1.
- **Loose M2 fails but T1 passes:** Variant B, with the room-by-room cut between proxies and copies set by the offline count gate.
- **Both fail:** keep one model scene with identical clips (model-against-model stays GPU-exact) and doodads as actors. Upgrade the copies' occluders from k-means boxes to per-bone convex hulls of the true Stand pose; offline that measured 0.05-0.28% wrong pixels against 3-10% today. Freeze the board's poses with SetAnimation(anim, 0, 0, t) or actor SetPaused so the hulls match.
- **The stock primitives misbehave in cell 2:** try the world/scale cubes (219363 and others, one-sided) and errorcube 166046 before dropping B.

**reliability_risks:**
- B actor count and cost: a naive exact cover is 10^4-10^5 primitives per room (measured above); findings.md cites a retail report of a single model costing about 10 FPS. B is viable only if the smart generator plus per-view culling stays inside the budget T5 measures.
- T1 could fail: UI textures between L0 and L3 might reset depth. That would kill L0+cover in both A-depth and B. The evidence suggests it passes: nothing clears between interleaved scenes (fact 5), and Blizzard needed allowOverlappedModels for shop cards (CLASS-44103). It is still unproven.
- Loose custom M2s may not load: the skin lookup by SFID FileDataID is the known blocker. That rules out A, A′ and A-full, the only routes to 100% exact and complete rooms.
- Proxies and doodads load asynchronously: until L0 has loaded, models draw over walls. Gate L3 on the L0 load callbacks.
- Placement conventions: the yaw/pitch/roll order, the board's mirrored y, and whether the client still centres file models on their GeoBox sideways (191087's GeoBox centre sits x +0.47 off its mesh). Wrong conventions misplace every proxy and doodad until calibrated.
- Clipping: the SetClipsChildren bug noted in findings.md (with several Model children only the first clips). If L0 is not clipped, it writes depth outside the board and could cut other UI models.
- Other addons' 3D frames overlapping the board pollute the shared depth buffer. If SetAllowOverlappedModels(true) turns out to clear depth, set it on L0 only.
- Nothing can be checked automatically: there is no pixel readback in Lua, and a client patch could change scene depth behaviour. Keep /dz 3d depthlab and a copies-mode switch in game.
- Data size: proxies and doodads add to about 12 MB of room data. A LoadOnDemand companion addon may be needed. Room files cannot be hot-patched, so each change is a full release.
- Generator complexity (cover plus gate) risks breaking rooms, as the 2026-10-05 rollback showed. Change one room at a time and render it before regenerating all.
- Depth precision is fine (24-bit, near 0.5: about 1 mm at 100 yd), but the inset must stay above it. Raising far or lowering near must apply to every scene at once.

**depends_on_unverified:**
- T1: depth written by a lower ModelScene survives opaque UI textures (DISABLE and BLEND) drawn between it and a higher scene, inside a SetClipsChildren frame like the board's.
- A: SetModelByPath loads a loose .m2 from Interface\AddOns. Tested as variant A (a game body copy with its real SFID) and variants B/C (MD20 with name00.skin, MD21 without SFID): does custom geometry load?
- D (fallback only): a custom material with Mod blend, white texture, unlit and unfogged, without flag 0x10, writes depth while staying invisible.
- Stock primitives 191087, 202326 and 167145 load with SetModelByFileID, draw at origin placement with SetUseCenterForOrigin(false,false,false), cull one-sided back faces, and write depth.
- The actor yaw/pitch/roll order and signs, including under the board's cam.mirror, and the limits on scale (about 0.03 to 40).
- The cost of 500 to 5,000 static actors in one paused ModelScene, plus about 300 doodads.
- Particles and transparent batches are depth-tested against another scene's depth.
- What SetAllowOverlappedModels(true) does: clear the depth buffer, isolate the scene, or something else.
- Doodad placement (MODD quaternion and scale to actor Euler angles and SetScale) matches the client's in-world placement.

**in_game_tests:**
- Ship one release with /dz 3d depthlab and Media/Test files made by a new gen_m2_testfiles.py, then restart the client once.
- Cell 1, T1, decisive. In a SetClipsChildren frame, scene P sits at level +2 with square 191087 scaled to about 6 yd, 20 yd away, covering the left half of Brutallus (display 22711). An opaque grey texture at +4 has a toggle between BLEND and SetBlendMode DISABLE. Scene C at +6 holds Brutallus 35 yd away. Same FOV, near 0.5 and far 1500. PASS: a square hole showing grey. Controls: square at 45 yd (behind him) shows him whole; square hidden shows him whole.
- Cell 1, button 'overlapped': scene C:SetAllowOverlappedModels(true). Note whether the hole goes. Print GetAllowOverlappedModels() for a fresh scene.
- Cell 2, calibration. Place 191087, 202326 and 167145 at known yaw, pitch, roll and scale 2-4 in a scene with mirrored y like the board, with UI dots at Project3DPointTo2D of their expected corners. Add a second square turned 180 degrees. PASS: the dots sit on the corners and the back-turned square is invisible. Repeat with doodad 191730.
- Cell 3, cost. Show 0, 500, 2,000 and 5,000 squares behind the cover plus 300 Black Temple doodads, and print GetFramerate() while orbiting.
- Cell 4, loose M2 (Logs\Model.log afterwards). For each variant, print C_UIFileAsset.IsLooseFile/GetFileID, SetModelByPath's return value, IsLoaded, GetModelFileID and GetActiveBoundingBox: A, a 191087 copy scaled x3 with its real SFID; B, MD20 with sq_b00.skin (v274 and v264); C, MD21 without SFID plus sq_c00.skin; D, the Mod-blend invisible square in front of a creature in a lower scene with no texture between. PASS for D: an invisible cut-out in the creature.

**build_plan:**
- 0. Depth lab: DepthLab in UI/StrategyMap3D.lua next to SceneTest, and dev/generators/gen_m2_testfiles.py writing Media/Test/*.m2, .skin and .blp. Remove SliceTest and the slices mode once results are in.
- 1. Exact data: move the scratchpad's local CASC reader into dev/generators/casc_local.py and point gen_rooms.casc() at the user's install. Rebuild ONE room and compare renders before rebuilding all.
- 2. One model scene with identical clips everywhere: the walker and remote walkers join the main scene; remove BACKDROP and scene0-for-creatures; turn View:Backdrop into the L0 depth scene plus the cover frame; re-level LV (L0 = 1, cover = 2, room0 from 4).
- 3. Doodads: wmo_tools.read_doodads (MODS/MODN/MODD/MODI), ADT MDDF, crop to the room box, new room section; spawn actors in L3 with the calibrated Euler order; add M2 collision to the walk data later.
- 4a. If loose M2 loads (cell 4 B or C): gen_room_m2.py writes the depth mesh (Opaque plus AlphaKey with real FDIDs); L0 holds 1-4 actors; L4 keeps only raised marks.
- 4b. Else, if T1 passed: gen_proxies.py (relevance sampling, cover with 191087/202326/167145, sinking, liquids, a flag for alpha-key screens) plus the render_check proxy z-buffer gate (0 wrongly hidden) and coverage report, with actor-pool culling in View. Adopt per room only if the proxy count fits the cell-3 budget; otherwise proxies for floors, liquids and large planes and L4 copies for the rest.
- 5. Room.lua: per-prim copy flag so CopyLeaves only copies flagged pieces; occluders only for those pieces and for raised mark segments; an in-game switch /dz 3d occlusion depth|copies.
- 6. Pilot one room at a time: Magtheridon (cut-outs), then the Lurker (water, submerged body), then Kil'jaeden (huge, alpha-key screens). Offline render to an image, then the user checks in game, then the rest.
- 7. If A loads: A-full. Visible native floors in L0, walls and props in L3, marks between; drop MAX_TRIS/MAX_NODES; translucent water optional; the Raid Trainer gets the same stack.
- 8. Fix the outdated notes: findings.md:89, View.lua:266-268 and the depth-slicing memory claim that 'a ModelScene does not sort models'. The real cause was mismatched clip ranges.

## Judges

### Judge 1: winner Design 1 (native room-as-M2 with a decision tree), with grafts: Design 4's crash guard and bounds probe, Design 2's exact Lua copies as the last fallback instead of hull copies, and Design 3's safety gate and same-look depth-only intermediate step
- Design 1 (native): room as M2 in the creatures' ModelScene, depth pre-pass sandwich as fallback: accuracy 9, reliability 7, feasibility 6, completeness 9. Best overall plan from an end user's view. If loose M2s load (Mode A), the GPU does the depth test the way the game world does. Every pixel is then correct against the live animation, real gear, doodads and water, and the face budget goes away. One test session settles every open question at once: loose models, depth surviving UI textures, SetAllowOverlappedModels, the per-pixel cut inside one scene, cost and alignment. That keeps trial-and-error rounds low. Each room checks itself at runtime and falls back to today's renderer if its files fail, so a client that refuses loose files gives the old view, not a broken one. Two encodings (own skins or reusing skin 189641) give two chances to pass. The 'floor split' keeps floor marks correct. It states plainly that Mode B is weak for organic rooms. Downsides: Mode A rests entirely on an unproven loader. Lighting changes the room's look, so the user must sign off. Room files add 20-60 MB of binaries that cannot be hot-patched. The last fallback (hull copies) is weaker than Design 2's exact copies.
- Design 2 (geometric): exact scanline copies against frozen true meshes (ESC), all in Lua: accuracy 7, reliability 7, feasibility 7, completeness 3. The only design with real offline proof. I checked esd_b3_*.txt: 0 wrong pixels out of about 17M across 96 views. It needs no unverified depth-buffer behaviour, and it handles alpha-key and blended room pieces and marks exactly. The end user still pays for it. Bosses must be frozen, so idle animation is lost. The prototype costs 15-62 ms per camera move per big boss. In walk mode the camera moves every frame, so this costs frame rate all the time, not only while orbiting, and Trainer waves with many units are out of reach. Particles, the player and party (live gear), and alpha-key model texels stay approximate. Every one of the 141 displays needs its own fit test (geosets, placement quirks like the Lurker offset), which means many more rounds of in-game testing. Completeness does not improve: the face budget stays and Lua time goes up. Excellent as the guaranteed fallback and for the leftover see-through pieces. A poor main path for a polished planner.
- Design 3 (hybrid): layered depth sandwich (L0 depth scene, cover, software room, one model scene, residual copies): accuracy 8, reliability 6, feasibility 5, completeness 6. Clever layering. Floor marks come out correct for free, and the offline safety gate (proxy depth >= room depth at every sampled pixel, 0 wrongly hidden) is the right discipline. Variant A (a depth-only custom M2 under the unchanged textured room) keeps today's look, which lowers the visual sign-off risk. But every variant except A-full needs T1 (depth surviving UI textures). The design's own measurement shows that Variant B needs 45k-170k squares when covered naively, so B is unproven until a filtered generator exists. The software room and the GPU depth disagree by up to 1.5 px at room edges. I checked its stock primitives: 191087 has a lopsided header box (x from -1.77 to 2.70) plus a bone with a rotation key, and 202326's header box is huge compared with its 3 vertices. If the client centres file models sideways on that box, placement is at risk. It has the most moving parts of the four (three renderers that must line up), so it carries the highest risk of trial and error across 55 rooms.
- Design 4 (contrarian): the room as a real model, one GPU depth buffer: accuracy 9, reliability 7, feasibility 5, completeness 9. Same target as Design 1 Mode A, with the strongest argument for why the sandwich is a ceiling, not the goal. It adds the best safety engineering: a bounds-signature probe at every room open, a crash-guard flag in saved variables, and an automatic fallback. Its decisive test is the simplest of the four (an edited unitcube with a borrowed SFID, an L shape that also checks handedness). Drawing rings as small M2 files is a good idea. Weaknesses: it is all-in on loose M2 loading. Overlays always draw on top, dimmed by ray tests, which is a step back from today, where marks are correctly hidden behind pillars. The fallback section is thin, and it lists 2199509 as a one-sided square. I checked that file: bone 0 has the 0x8 billboard flag, so it cannot be used. A borrowed skin (496338) depends on a single Blizzard file, and borrowed-skin files are about 3x larger.

Fatal flaws:
- Design 2: bosses must be frozen (no idle animation). Each camera move costs 15-62 ms per big boss (the lupa prototype is not optimised, and WoW's Lua speed is not measured). In walk mode the camera moves every frame, so frame rate drops all the time, and Trainer waves cannot afford it. It does nothing for completeness, and it needs a per-display fit test across 141 displays, which means many in-game rounds. Not acceptable as the main path for a polished planner.
- Design 3: every non-A-full route depends on T1. Variant B's own measurement is 45k-170k primitives per room when covered naively, so the proxy route is unproven until a filtered generator exists. Its flat primitives 191087 and 202326 have header boxes far off their mesh (checked), so sideways centring could shift every proxy. Three renderers must line up to under 1.5 px.
- Design 4: its fallback names 2199509 as a usable one-sided square. I checked the local file: bone 0 has the 0x8 billboard flag, so it turns to face the camera. Overlays always draw on top (dimmed by ray tests), which loses today's correct hiding of marks behind pillars. It is all-in on one unproven loader assumption, with a thin fallback.
- Design 1 (not fatal, but serious): Mode A rests entirely on loose M2 loading, which nobody has shown publicly on a CASC client. Mode B is admitted to be only 'within delta' on organic rooms. The room's look changes (scene light instead of baked WMO light), so the user must sign off per room. Room binaries cannot be hot-patched.
- All GPU designs: depth is shared with every model frame drawn earlier in the UI (portraits, other addons). It can punch holes in the board unless SetAllowOverlappedModels or a strata choice isolates it, and that is untested.

### Judge 2: winner Design 1 (native): room as M2 in the creature scene, depth pre-pass sandwich as fallback
- Design 1 (native): room as M2 in the creature scene, depth pre-pass sandwich as fallback: accuracy 9, reliability 7.5, feasibility 6.5, completeness 8.5. It only uses documented 2.5.6 calls: SetModelByPath, SetModelByFileID, near/far clip, SetAllowOverlappedModels, SetPaused. Every unverified behaviour has a cheap in-game test, and one test session picks the mode. It has the fullest fallback ladder: A1/A2, then B, then slicing (only if the overlapped flag isolates depth), then hull copies. It also re-checks each room at runtime (load success, OnModelLoaded timeout, GetModelPath), so a client that refuses loose models falls back to today's view instead of a broken one. I checked its claim that fact 5 is indirect evidence for T1. Room.lua SL.Levels (L2997-3037) does put the nearer bands' room frames between the far band's slice scene and the near band's scene. So depth did survive across frame levels with room textures in between, but it is unknown whether those textures covered the exact pixels. That makes it suggestive, not proof. It correctly rules out the billboard squares (2199509/2199319). It also explains why an invisible depth mesh cannot sit inside the creature scene: translucent batches draw after opaque ones. Weak points: Mode B uses cubes only and underestimates the actor count (Design 3 measured 45k-170k for a naive cover). Mode A rests on a loose M2 loading, which nobody has shown publicly on a CASC client. The scope is two large pipelines.
- Design 2 (geometric): exact scanline copies against frozen true meshes, done in Lua: accuracy 7, reliability 6.5, feasibility 6, completeness 3. It is the only design that relies on no unverified depth-buffer behaviour. Copies drawn over a scene and sorting inside one scene are already proven in game, and the offline prototype got 0 wrong pixels out of 17M. But its correctness in game rests on other unverified things: SetAnimation(0,0,0,0) or SetPaused freezing the pose at exactly frame 0, the client picking the same geosets, and placement being exact for every display (the Lurker's offset history argues against assuming that). The fit test for these is not cheap: it needs an offline mesh exporter plus a Lua row engine. CPU cost: 15-20 ms median and 34-62 ms worst per camera move, per boss, measured in lupa. WoW runs the same Lua 5.1, so expect similar cost. That stays under 'script ran too long', but frame rate drops while orbiting, and multi-boss fights (Council, Eredar Twins, Trainer waves) multiply it. It cannot reach '100% in all encounters' because of the leftovers listed under fatal flaws. It does nothing for completeness and adds Lua load. It is the best last-resort fallback, not the target.
- Design 3 (hybrid): layered depth sandwich (L0 depth, cover, software room, one model scene, residual copies): accuracy 8, reliability 7, feasibility 6, completeness 7. This design has the strongest engineering safeguards. Its offline gate (a proxy may never be nearer than the drawn room, with 1-px erosion) makes wrong hiding impossible at every sampled view. It notes that floor marks come out exact for free when the depth scene L0 sits under the room. It found real non-billboard stock primitives in the local client: 191087 flat square, 202326 triangle, 167145 cube. Variant D, an invisible Mod-blend depth mesh in a scene directly under L3, removes the dependence on T1. It also names the SetClipsChildren 'only the first Model child clips' risk, which would leak L0 depth outside the board. It is honest that a naive Variant B needs 10^4-10^5 actors per room, far beyond any plausible ModelScene actor budget. B therefore lives or dies on relevance filtering, which is unproven. Variant A, the depth mesh under textures, stacks two unverified behaviours (loose M2 and T1) unless A-full or D is used. A-full leaves about 1 px of seam where the software room's silhouette meets the GPU's depth. Free-standing alpha-key screens keep today's error class, and those are 9-20% of the room area in Kil'jaeden, Twins, Teron and M'uru.
- Design 4 (contrarian): the room as a real model, one GPU depth buffer: accuracy 8.5, reliability 5, feasibility 5.5, completeness 9.5. It is the right end state if it works: the same depth test the game world uses, with live animation, real-gear players and particles against walls, no face budget, and rooms in the client's M2 cache instead of 12 MB of Lua strings. The decisive probe is the cheapest and best designed of all four. A unitcube body pulled into an asymmetric L tests loose-body loading and handedness in one restart. The borrowed skin 496338 (434 disjoint quads) is a credible A2. But the whole design rests on one behaviour that is unverified and historically unproven: loose M2 loading through SetModelByPath. A later client patch could also silently block it. Its crash guard does not work (see fatal flaws). Its fallback list includes 2199509, which is a spherical billboard and unusable as a proxy. Marks are drawn on top and only dimmed by ray tests, which is less exact than the floor split in Designs 1 and 3. Borrowing skins ties the files to the exact client build.

Fatal flaws:
- Design 4: the crash guard does not work. SavedVariables are written to disk only on logout, ReloadUI or a clean exit, so a flag set before a risky SetModelByPath is never on disk when the client hard-crashes, and the guard never fires. It would need a deliberate ReloadUI before the first risky load, or a staged 'probe once, persist the result after a clean reload' scheme.
- Design 4: the whole plan depends on loose custom M2 loading, which nobody has publicly shown on a CASC client. Its fallback proposes 2199509, a billboard, as a wall proxy, so the fallback as written is partly unusable.
- Design 2: it cannot meet the goal of 100% per pixel in all encounters. Particles, blended effect triangles (Kil'jaeden's 3,956), alpha-key model texels, and the player and party (live gear, run cycle) stay approximate. It also needs every boss frozen (lost idle animation, a UX regression), and its Lua cost (15-62 ms per camera move per boss) multiplies in multi-boss fights. It adds nothing to room completeness.
- Design 3: Variant B, its main path when loose models fail, needs 45k-170k primitives per room for a naive cover, far beyond any plausible ModelScene actor budget. It is viable only if relevance filtering, which is still unproven, cuts that by 1-2 orders of magnitude. Variant A, the depth mesh under the room textures, needs loose M2 and T1 at the same time.
- Design 1 (not fatal, but the main weakness): Mode B's cube-only cover underestimates the actor count for organic rooms. Both of its exact modes rest on behaviour not yet tested directly in game (loose M2, depth surviving UI textures over the same pixels). Fact 5 only shows depth survived across frame levels with room frames in between.

### Judge 3: winner Design 1 (native): room as M2 geometry in the creatures' ModelScene, with the depth pre-pass sandwich and better copies as staged fallbacks. Its Mode A is the only route that can reach 100% per-pixel correctness across animation, live player gear, doodads, water and huge models, and it is the only design with a verified skin-reuse encoding (A2) that raises the odds of Mode A. Its decision tree degrades per room to the existing renderer instead of breaking. It should take Design 3's safety gate and Design 2's exact-copy engine for whatever the GPU path cannot cover.
- Design 1 (native): room as M2 geometry in the creatures' ModelScene, depth pre-pass sandwich as fallback: accuracy 9, reliability 7, feasibility 6, completeness 9. This design has the highest ceiling and the most complete decision tree. In Mode A the room, doodads, creatures and the walking player share ONE scene and ONE clip range. Facts 4 to 6 say that is the one configuration the client is known to sort correctly. Animation phase, the player's live gear, water tint and huge models (Kil'jaeden) then become exact with no Lua work. I checked its claims against the local 2.5.6.69795 files. Skin-reuse donor 189641 / skin 494450 is a single static bone with 4,022 triangles in 1,700 vertex-disjoint pieces (679 single triangles, 750 two-triangle pieces). The claim that the 'invisibletrap' squares 2199509 and 2199319 are billboards is correct: bone 0 has flag 0x8. Its reason why an invisible depth mesh cannot sit in the creature scene is sound: translucent batches are drawn after the opaque creatures. The symmetric header boxes, which make the client's sideways centring a no-op, are a smart detail. Weak points: (1) It overstates fact 5 as evidence for T1. Room.lua SL.Levels (2997-3037) does put the far-band scene below the middle bands' room frames and the near scene above them. So fact 5 shows that depth is not cleared between frame levels and UI draws. But the far model was VISIBLE at the player's pixels, which means no opaque room texture was painted on those pixels in between. Whether a texture painted over the same pixel preserves depth is still untested. (2) Mode B does not say that proxies must come only from the faces the cropped renderer actually DRAWS. Otherwise models behind budget holes are rejected and the backdrop shows. (3) The 1.5 px agreement between the Lua projection and the engine (Room.lua:65 self-check) means seams at Mode B edges; it needs inset or erosion. (4) Particles are only 'assumed' depth-tested. Fact 2, that particles ignore the clip planes, hints they take a different projection path. (5) A loose file with no ModelFileData row may fail the LOD-count lookup: the exe string 'forceLODCheck ... skip checking DBC for LOD count' implies the client checks it by default. Minor: it underrates its own floor split. A floor mark in front of a model's legs IS shown correctly, because the floor depth rejects the model there.
- Design 2 (geometric): Exact scanline copies (ESC) against frozen true meshes, all depth in Lua: accuracy 6.5, reliability 7, feasibility 6.5, completeness 4. This is the only design that needs no unverified depth-buffer behaviour. It has the strongest offline evidence: 0 wrong pixels out of about 17M against a z-buffer of the same mesh, in the shipped rooms. Room pieces are copied with their own texture and UVs, so alpha-key railings, blended room pieces and mark lines come out exact. No proxy design can do that. But its ceiling is clearly below the user's goal of 100% correct in all encounters. Bosses must be frozen at Stand frame 0, so the board loses idle animation. The Raid Trainer's walking and running units cannot be frozen at all. The player and party (SetModelByUnit, live gear, run cycle) are only approximated with hulls. Particles are never handled. Alpha-key texels on models are treated as solid. Blended effect triangles (Kil'jaeden's 3,956) are wrong in one direction. 'Pixel-exact in game' is also limited by how well the Lua projection matches the engine: Room.lua's self-check only warns above 1.5 px. So expect fringes of up to a pixel, not 0. Cost: 15-20 ms median and 34-62 ms worst per camera move per big boss in PUC Lua. That comes on top of the existing room render, and multi-boss encounters scale it up. It does nothing for completeness: baking doodads into the Lua room makes the face budget worse. It also depends on the pose, geosets and placement matching per display, which the Lurker's offset history shows is not a given. It is the best fallback, and the best engine for whatever the GPU path cannot cover, but not the winner.
- Design 3 (hybrid): layered depth sandwich (L0 depth scene, cover, software room, one model scene, residual copies): accuracy 8, reliability 7, feasibility 5.5, completeness 7. Solid engineering with the most honest self-measurement. Its own cover count, 45k-170k squares for a naive exact cover, shows that the stock-primitive Variant B is marginal on organic rooms unless relevance culling and overshoot cut it by 1-2 orders of magnitude. Strong ideas: the offline safety gate (proxy depth never nearer than the DRAWN room, with 1-px erosion, so nothing is hidden wrongly) and the argument that floor marks become exact for free under L0. The staged path, a depth-only custom M2 under today's textures first and then A-full, keeps the look unchanged while proving the depth. I checked 191087 locally: all 49 vertices are on static bone 0, it is a one-sided 7x7 grid in the x=0 plane, and it is a real usable square. But its mesh is offset from the origin (z 1.94-3.61) and its header box is much larger than the mesh, so placement needs calibration. The 202326 triangle has fixed angles and uniform scale only, so it cannot tile arbitrary triangles. It is little use beyond corner patches. Both A-depth and B depend on T1. In B, alpha-key screens (9.5-20.6% of room area in the Sunwell rooms) keep today's part-box error. Its A-prime borrowed-skin path still had no donor found, whereas Designs 1 and 4 did find one. Particle depth against L0 is an assumption, given fact 2.
- Design 4 (contrarian): room shipped as M2 files in one GPU depth buffer with creatures and doodads: accuracy 8, reliability 5, feasibility 4.5, completeness 9. Right in principle: one renderer with one depth buffer is what a graphics engineer would choose. Its decisive probe is the cleanest. It edits unitcube into an L shape and keeps the borrowed skin 492738, which I verified as 6 disjoint 2-triangle quads, so moving one quad is valid. Its donor skin 496338 (model 193019) was also verified locally: 434 disjoint 2-triangle quads on a single static bone. Problems: (1) It is all-in on one undocumented capability, loading a loose M2. It ignores the possible ModelFileData LOD-count lookup for files with no DB row. (2) The crash guard as written does not work. SavedVariables are only written at logout or /reload, so a flag that is 'set before loading and cleared after' never reaches disk if the client crashes mid-load. The flag must be persisted with a ReloadUI before the risky load. (3) The bounds-signature probe assumes GetActiveBoundingBox returns the file's header box. For creatures it returns the DB GeoBox (fact 8), so for a loose file it may return nothing useful. (4) Its fallback (1) lists spellobject_invisibletrap 2199509 as a proxy. That model is a spherical billboard (bone flag 0x8, verified), so it cannot model walls. (5) It claims particles are depth-tested against walls 'by construction', which is hand-waved given fact 2. Completeness is excellent if the probe passes, and its fallback chain is thinner and partly wrong if it does not.

Fatal flaws:
- Design 4: fallback (1) relies on spellobject_invisibletrap 2199509 (and 2199319) as a wall proxy. Both have bone 0 flag 0x8 (spherical billboard) in the local 2.5.6.69795 files, so they turn to face the camera and cannot represent walls.
- Design 4: the crash guard cannot work as specified. SavedVariables are only written at logout or /reload, so a flag set before loading and cleared after loading is never on disk when the client crashes during the load. The fix is to persist a 'native pending' flag with ReloadUI before the first risky load, and to clear it only after a clean session.
- Design 4 (and partly 1 and 3): particle and room depth correctness is claimed or assumed. Fact 2 (particles ignore the scene's near/far clip) suggests particles use a different projection or depth-clip path, so their depth test against room geometry (in-scene or a lower scene) is unverified. No design includes a direct particle-behind-wall test.
- Design 2: by construction it cannot meet '100% per-pixel in all encounters'. It needs frozen poses (no idle animation, and the Trainer's walking units cannot be frozen), approximates the player and party with hulls, never handles particles, treats alpha-key model texels as solid, and is limited in game by Lua-vs-engine projection agreement (Room.lua's self-check tolerates 1.5 px), not 0 px. It costs 15-60 ms of Lua per camera move per big boss before multi-boss scaling.
- Design 1: it overstates fact 5 as evidence for T1. SL.Levels (Room.lua:2997-3037) does put the far scene below the middle bands' room frames and the near scene above them, so depth is not cleared across frame levels or UI draws. But the far model was visible at the player's pixels, so no opaque room texture was painted on those pixels in between. Whether a texture painted over the same pixel preserves depth (the sandwich's actual requirement) is still unknown.
- Designs 1 and 3, Mode/Variant B: proxies must be built only from the faces the cropped, budgeted texture renderer actually draws, and inset past its silhouette error of up to 1.5 px. Otherwise a model behind a missing face is depth-rejected and the opaque cover/backdrop shows through as a hole. Design 3's gate covers this; Design 1 does not say it.
- Design 3, Variant B: its own measurement (45k-170k squares for a naive exact cover) makes stock-primitive proxies likely infeasible on organic rooms without heavy relevance culling. The 202326 triangle has fixed angles and only uniform scale, so it cannot tile arbitrary triangles. Alpha-key screens (9.5-20.6% of room area in Sunwell rooms) stay on today's part-box error.
- All loose-M2 paths (Designs 1, 3 A and 4): the exe string 'forceLODCheck: If enabled, we will skip checking DBC for LOD count' implies that by default the client looks up ModelFileData for LOD count. A loose file with a negative ID has no row, which may fail skin selection even for a byte-copy body. The decisive probe must expect this and report Logs\Model.log.

## Final recommendation

# Room vs model depth: best approach for DisasterZone's 3D strategy board

## 1. Recommendation: put the room into the client's own depth buffer as real model files

The only per-pixel depth test the addon can reach is the model renderer behind ModelScene. All scenes with the same camera and clip range share that one depth buffer (facts 4-6). So the Lua approximation goes, and the room becomes model geometry instead:

- A generator reads the room straight from the installed client, build 2.5.6.69795 (not 2.5.5): walls, floors, terrain and liquids.
- It writes the room as loose `.m2` files inside an addon folder. The files use Blizzard's own texture IDs, so no textures ship.
- The game loads them with `actor:SetModelByPath` into the same ModelScene as the bosses, the player's walking character and the room's props. The props are Blizzard's own models from the WMO/ADT doodad lists, loaded with `SetModelByFileID`.
- Result: one scene, one clip range, one depth buffer. This is the same depth test the game world uses.

It ships in two steps:

1. **Depth only, same look.** The room mesh is an invisible depth writer: white, unlit, Mod blend, depth write on. It sits in a scene directly above today's textured room and below the creature scene. Occlusion moves to the GPU and the room looks the same as now. What's left: a seam of at most 1.5 px where the Lua-drawn room edge and the GPU depth disagree.
2. **Native room.** The GPU draws the room itself. This removes the 7000-face budget and gives perspective-correct textures, the missing props, moving water and no holes. Lua keeps only collision, walking and picking.

**How accurate step 2 is:**
- **Exact per pixel:** every opaque or alpha-key surface against every other, in any animation frame. That covers the room, props, huge models like Kil'jaeden and your character in real gear. Depth resolution is about 1 mm at 100 yd.
- **Not exact:**
  - Two see-through surfaces on top of each other are ordered per object, as in the game.
  - Particles against the room are unproven. Fact 2 (particles ignore clip planes) hints they take a different path.
  - Board drawings are UI. They need a "floor split" (floors in a lower scene, then marks, then everything else) or small model rings.
  - Room lighting changes from baked lighting to scene light. That needs the user's sign-off per room.

## 2. Why not the others

- **Proxy sandwich** (stock cubes under the room textures): exact only on box-like faces. Organic rooms need 45k-170k cubes if covered naively, and it relies on depth surviving the room textures (untested). It is the first fallback.
- **Exact Lua copies:** 0 wrong pixels out of 17M offline, but:
  - bosses must be frozen;
  - it costs 15-62 ms of Lua per camera move per boss, which in walk mode is every frame;
  - it never handles particles or players in live gear;
  - it adds nothing to room completeness.

  It is the last-resort fallback.
- **Depth slicing:** wrong by design, because each scene's depth is scaled to its own clip range. It only becomes usable if `SetAllowOverlappedModels` gives each scene its own depth, and even then accuracy is limited by band thickness.
- **Better boxes or hulls:** 0.05-0.28% wrong pixels at best, against 3-10% today.
- **Pre-rendered images, the world camera, cutaway walls:** they lose orbit and walk mode, or don't fix depth at all.

## 3. Verified vs unknown, and the single probe

**Verified:**
- Same-clip scenes share depth; models inside one scene sort correctly.
- `SetModelByPath`, `SetAllowOverlappedModels`, actor `SetPaused` and `Project3DPointTo2D` exist in this client.
- `spells/unitcube.m2` (167145) is a clean, centred, opaque cube.
- Two Blizzard skin files can host our own geometry: 494450 (from model 189641, 1,700 separate pieces) and 496338 (434 separate quads).

**Unknown, and decisive:** whether loose `.m2` files load at all. Nobody has shown it publicly on this kind of client. The executable also hints at a database lookup (LOD count) that a loose file has no row for.

Build `/dz 3d probe` with test files in `Media/Probe`, generated from the local client files and passed through a strict validator. Do a full client restart first. Crash guard: set a "probe pending" flag and call `ReloadUI()` before the risky panel, because saved variables only reach disk on reload or logout. Clear the flag after a clean session.

| Panel | Test | What it decides |
|---|---|---|
| 0 | Dump every method of ModelScene, actor, PlayerModel and Frame (`pairs(getmetatable(x).__index)`) into SavedVariables. Also `pcall(CreateFrame, "OffScreenFrame")` and `"UiCamera"`, and `GetBuildInfo()`. | Confirms nothing undocumented exists. |
| 1 | Loose models, with the stock cube as control: (a) a copy of unitcube bent into an asymmetric L, real skin and texture IDs; (b) the file without its skin ID, plus its own `.skin`; (c) the old MD20 format plus `.skin`; (d) a model reusing skin 494450, shown as a textured checkerboard; (e) an invisible Mod-blend square in a lower scene, in front of a creature. Print `IsLooseFile`, `GetFileID`, the `SetModelByPath` result, `IsLoaded`, `GetModelFileID`, `GetActiveBoundingBox`, and read `Logs\Model.log`. | L visible: loose models load (and handedness is known). (b) or (c): we can ship our own skins. Only (d): skin reuse. (e) cuts a hole: step 1 works without panel 3. Nothing or an error cube: the native route is dead. |
| 2 | A cube pushed through Brutallus in one scene. | Must show a straight cut line (per-pixel depth inside one scene). |
| 3 | Cube scene, an opaque texture over the same pixels, creature scene behind. Inside a clip frame like the board's, with blend DISABLE, ALPHAKEY and BLEND, a strata change, and texture off as control. | A cube-shaped hole means the sandwich and the floor split are viable. |
| 4 | `SetAllowOverlappedModels` on the creature scene, then on the cube scene; print the getter on a fresh scene. Add a model in MEDIUM strata under the board. Rerun slicing with the flag on. | Whether the flag isolates depth, and whether other UI models punch holes into the board. |
| 5 | Actor alpha 1, 0.5 and 0.01 as a depth writer. | Whether see-through actors can block depth. |
| 6 | A boss glow behind a cube, in the same scene and across scenes. | Whether particles are depth-tested. |
| 7 | `Project3DPointTo2D` depth for a fixed point at several near/far settings. | Confirms per-scene depth scaling. |
| 8 | Calibration: an asymmetric prop at yaw/pitch/roll 30/20/10 with dots at its expected corners. Freeze with `SetAnimation(0,0,0,0)` and with `SetPaused`, against an offline outline. | Rotation order, and whether poses freeze exactly. |
| 9 | Cost: 250, 1000 and 4000 paused cubes, 300 Black Temple props, one 50k-triangle room file. Read `GetFramerate` and `debugprofilestop`. | Budgets for every route. |
| 10 | Only if panel 1 passes: Magtheridon's room file under the textured room at 50% alpha. | Edges must line up within 1 px while orbiting and walking. |

## 4. Build plan

**Phase 0 (useful whatever the probe shows):**
- Read every game file from the installed client instead of wago downloads. 101 of 290 WMO groups differ, and the downloads have about 9% fewer triangles, which causes holes. Rebuild Magtheridon first and compare.
- Put every model, the walking player included, into one scene with identical clips.
- Add props as actors, but only file IDs verified as models in this client (a non-model ID crashes the game).
- Correct the outdated notes in `findings.md:89` and `View.lua:266-268`.

**Phase 1:** build the probe kit and the M2 writer with its validator. The user runs the probe once and the results go into project memory.

**Phase 2A (loose models load):**
- Step 1 room by room: Magtheridon, then the Lurker, then Kil'jaeden.
- Then step 2, with the room files in a load-on-demand `DisasterZone_Rooms` addon.
- Each room checks at runtime that its files loaded (success, load timeout, bounds). If not, it falls back to today's textured renderer. Keep `/dz 3d renderer ui` as a manual switch.
- The Raid Trainer gets the same renderer.
- Full releases only: binary files can't be hot-patched.

**Phase 2B (loose models fail, panel 3 passes):**
- Unitcube proxies, built only from faces the renderer actually draws, sunk slightly into the surface.
- An offline check in `render_check`: a proxy may never be nearer than the drawn room, with 1 px erosion, and nothing ships until it reads 0 wrongly hidden pixels.
- Only show proxies near models, with the count capped by panel 9.
- Exact Lua copies for see-through room pieces.
- Never use 2199509 or 2199319: they always turn to face the camera.

**Phase 2C (both fail):**
- Exact Lua copies against frozen boss meshes extracted offline. Use per-bone hulls while the camera is being dragged, and exact copies once it stops.
- An automated offline check of the Lua engine against the reference z-buffer.
- Slicing only if panel 4 shows that the flag isolates depth.
