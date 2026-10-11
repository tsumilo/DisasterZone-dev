# Refactor 1.4: shared API contract

Every agent in the 1.4 refactor codes against these names, so work done in parallel fits together. The foundation and
component agents BUILD these; the migration agents USE them. If a builder finds a signature unworkable, it may extend
it (extra optional fields / methods) but must not rename or drop what is listed here. Plan: dev/docs/REFACTOR_PLAN.md.

Decisions taken by the user (11 Oct 2026):
- D1 two golds: `GOLD` 1,0.82,0 for text/accents; `GOLD_DEEP` 0.91,0.73,0.14 only for fills and edges.
- D2 snap half font sizes (9.5, 10.5, 11.5, 12.5 ...) to the named scale; small visual shifts are accepted.
- D3 every list+detail profile/detail gets a banner; boards get a hero card for the top item; Settings has none.
- D4 Sunwell short name is "SWP".
- D5 overkill counts in damage everywhere (My Log follows Meters).
- D6 shared 3D camera code with zoom step and easing as per-view options (each view keeps today's feel).
- D7 ships as its own release, 1.4.0.

## 1A. `ns.Style` (UI/Style.lua, loaded before Widgets.lua). Local alias in files: `local S = ns.Style`

Values are taken from the most common values in the code today (so migration is close to pixel-identical).
```
S.C.GOLD, GOLD_DEEP, TEXT, SUB (0.62 grey), DIM, YOU, LIVE, OK, WARN, BAD     -- {r,g,b[,a]}
S.C.SURFACE_WINDOW, CARD (0.10,0.10,0.12,0.92), INSET, QUIET, EDGE (0.34,0.34,0.38,0.55), EDGE_QUIET,
    HAIRLINE (1,1,1,0.07), HOVER (1,1,1,0.05), SELECT (1,0.82,0,0.10), SELECT_BAR (= GOLD), STRIPE
S.HEX.<NAME>            -- "ffd100" style hex for |cff codes;  S:Hex(name) -> "|cffffd100";  S:Wrap(name, text)
S:Color(name)           -- r, g, b, a  (unpack-friendly)
S.FONT = { hero = 19, page = 17, title = 13, emph = 12, body = 11, small = 10, caps = 9.5 }   -- the only sizes
S.STYLE[name]           -- { size, font (path or font object), color = token name, caps = bool, spacing } for
                        -- "hero","page","title","emph","body","small","caps","num","link"
S.PAD = 10, S.GAP = 8, S.IN = 8
S.ROW = { compact = 22, list = 26, rich = 38, art = 50 }
S.BANNER = { hero = 128, tool = 84, strip = 46 }
S.BTN_H = 24            -- the one height of a page's main action
S.PAGE_W, S.PAGE_H, S.INNER_W  -- the main window's page area (MainFrame reads these, pages must too)
```
`EUI.GOLD/GREY/DIM/TEXT/CARD/EDGE/PAD/GAP`, `UI.WIN_BG`, `UI.DROP_BG/DROP_EDGE`, `UI.HUD_BG` etc. become aliases of
these (same tables), so old reads keep working until the last caller is migrated.

## 1B. Primitives in `ns.UI` (UI/Widgets.lua)
```
UI:Text(parent, style, color, opts) -> FontString
    style: a S.STYLE name, or a number (legacy, snapped to the scale); color: token name or {r,g,b,a};
    opts: { layer, justify, wrap, width, shadow, flags, font }
UI:SetTextStyle(fs, style, color)
UI:Fill(parent, color, layer, sublevel) -> Texture (all points)
UI:Gradient(tex, orient, c1, c2)          -- "HORIZONTAL"/"VERTICAL", colours {r,g,b,a}; sets the texture white first
UI:Rule(parent, opts) -> Texture          -- 1 px hairline; opts { color, alpha, top/bottom/left/right offsets, vertical }
UI:FitText(fs, text, maxWidth)            -- truncate with "..."
UI:TextWidth(text, style)
UI:AttachTooltip(frame, title, lines, opts)   -- title may be a function(frame, tooltip); opts { anchor, owner }
UI:Pool(parent, create, reset) -> pool    -- pool:Acquire() / :ReleaseAll() / :Each(fn) / :Active()
UI:HideFrom(list, first)                  -- hide list[first..#list]
UI:ItemText(id) / UI:ItemIcon(id) (fallback 134400) / UI:ItemName(id) / UI:ItemLabel(id) (link or name)
UI:FitModelCamera(model)
UI:SavePosition(frame, key) / UI:RestorePosition(frame, key, default...)   -- the ONE window-position store
```

## 1C. Shared data helpers
```
ns.Util.Now(), Util.IsInt(v), Util.DemoOn(), Util.Jitter(key, spread), Util.NewRng(seed)
ns.SlotLabel(sid)                    -- one fallback: "Slot N"
ns.ClassName(classFile, localized)   -- localized = true -> client's localized name, else English ns.CLASS_NAMES
ns.SPECS[...].icon                   -- spec icons live on the spec table
ns.Util.ShortName(name, anyRealm)    -- existing; anyRealm = true strips every realm (the games' behaviour)
ns.UI:ClassOf(name) / ns.UI:ColoredName(name)   -- existing, the only versions
ns.DB:GuildBucket(key, create)       -- "this guild's saved table for <key>, created if missing"
```

## 1D. Raid information (Data/Raids.lua + Core/ItemDB.lua)
```
ns.Data.RaidMeta[itemKey] = { short, planKey, instanceID, art = { fdid|path, l, r, t, b }, artTop, mapNames, mapIDs }
ns.ItemDB:GetRaidByInstance(instanceID) -> itemKey, raid
ns.ItemDB:GetRaidByPlanKey(planKey)     -> itemKey, raid
ns.ItemDB:PlanKeyOf(itemKey) / ItemKeyOf(planKey)
ns.ItemDB:RaidShort(key)               -- either key form; Sunwell = "SWP"
ns.ItemDB:RaidArt(key)                 -- either key form -> path/fdid, l, r, t, b (crop under the logo band)
```
`RaidPlanUI:RaidArt` stays as a thin wrapper. Both key forms stay valid forever (saved data uses them).

## Phase 2 components (UI/Comp/*.lua; all on `ns.UI`)
PageParts.lua
```
UI:CreatePageBanner(parent, opts) -> banner
    opts { size = "hero"|"tool"|"strip"|number, art = raid key | {path, l, r, t, b}, icon, kicker, title, sub,
           pill = {kind, text}, back = {text, onClick}, actions = { {text, kind = "primary"|nil, onClick, width, menu} } }
    banner:SetTitle / SetSub / SetKicker / SetArt / SetIcon / SetPill(kind, text) / SetActions(list) / SetBack(text, fn)
    banner.foot  -- a frame along the banner's bottom edge for tabs that sit on its foot
UI:CreateBackLink(parent, text, onClick) -> button
UI:CreateSectionHeader(parent, title, opts) -> header
    opts { style = "title"|"caps", count, right, rule = true, action = {text|icon, onClick, tip} }
    header:SetTitle / SetCount / SetRight / SetAction
```
Surfaces.lua
```
UI:CreateCard(parent, opts) -> card    opts { tone = "card"|"inset"|"quiet", title, titleStyle, pad }; card.body
UI:DecorateRow(row, opts)              opts { hover = true, selectable, stripe, rule }; row:SetSelected(b), row:SetStripe(i)
UI:CreateArtRow(parent, opts) -> row   (50 high: 64x38 art + 20 px icon badge, title, sub, right slot);
                                       row:SetData{ art, icon, title, sub, right, pill }
UI:CreateEmptyState(parent, opts)      opts { icon, title, text, action = {text, onClick} }; :SetContent(opts)
UI:CreateNotice(parent, kind, text)    kind "readonly"|"locked"|"loading"|"info"; :SetNotice(kind, text)
scrollList:SetEmptyState(opts)         (next to the existing SetEmptyText)
```
Controls.lua
```
UI:CreatePill(parent, kind, text)      -- THE pill; kinds = every TAG_LOOK kind + live, rank, review, draft, ended ...
                                        -- UI:CreateTagPill and EUI:CreatePill become aliases of it
UI:CreateChip(parent, opts)            opts { text, icon, onClick, selected, kind }
UI:CreateSegments(parent, items, onChange, opts) -> seg; seg:Select(i|key), seg:GetSelected()
UI:CreateRailNav(parent, items, onSelect, opts) -> rail; rail:Select(key), rail:SetCount(key, n)
```
Overlays.lua
```
UI:Toast(opts)                         opts { key, title, text, icon, duration, onClick, kind }
UI:CreateSheet(parent, opts) -> sheet  opts { title, width, height, onClose }; sheet.body, :Open(), :Close()
ns.Popup:Confirm(opts)                 opts { title, text, ok, cancel, danger, onAccept, onCancel }
ns.Popup:Prompt(opts)                  opts { title, text, default, ok, validate, onAccept(value) }
UI:CreateHudFrame(name, opts) -> frame opts { width, height, position = key, strata, movable, lockable, onMoved }
```
Themes.lua / MapArt.lua
```
ns.Themes:Define(kind, list, defaultKey); :Get(kind, key); :Current(kind); :SetPreview(kind, key|nil)
UI:CreateThemeTiles(parent, kind, opts) opts { tileW, tileH, gap, paint = function(tile, theme), onPick }
ns.MapArt.Layer(mapID); ns.MapArt.Tiles(pool, parent, layer, files, ox, oy, scale, opts); ns.MapArt.Yards(mapID)
```
Layouts.lua (phase 3)
```
UI:CreateLayout(kind, parent, opts) -> layout        kind "board"|"listdetail"|"detail"|"rail"|"tool"
    layout.toolbar   :SetTabs(tabs, onSelect) :SetPrimary{text, onClick} :SetFilters(frames) :SetMore(menuFn)
    layout.body / .side / .list / .detail / .banner / .rail (whichever the kind has)
    layout:ShowEmpty(opts) / :HideEmpty() / :ShowNotice(kind, text) / :HideNotice()
ns.MainFrame:RegisterTab(key, label, order, createFn, isAvailableFn, opts)   opts { layout = kind } (optional)
```
Every page and window ends up on one of the five layouts. Main action: one height (S.BTN_H), far right of the toolbar.

## Testing notes (added 11 Oct, applies to every agent)
- The machine is shared: at most 3 agents run at once and `dz.sh` caps each test run at 3 suites (DZ_TEST_SLOTS).
  Don't raise it, and don't start several run_all.py at once.
- Test selection is smarter now (commits 1b85163, 5d62b78): files are hashed when a suite reads them, so you can keep
  editing while suites run (no more "no record yet" full reruns); a top-level for/do/if block that only fills tables,
  and `a.X, a.Y = ...`, count like data-table changes. Top-level code that registers events or calls into the addon
  still reruns every suite that loads the file: keep such code in functions (e.g. an init function called from one
  place) where the design allows.
- During work run run_all.py (selection) or single suites; the integrators run the broad checks.
