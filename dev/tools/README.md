# DisasterZone offline test toolchain

Static checks and a mocked WoW TBC Anniversary client (2.5.x, Interface 20506, Lua 5.1) for the `DisasterZone` addon.
Nothing here touches the WoW folder; the addon is only read.

**Python to use** (lupa 2.8 with a real Lua 5.1):

```
C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\ad52e6fc-e309-49be-aa3a-9ce45a30ad4b\scratchpad\luaenv\Scripts\python.exe
```

Every tool also puts `luaenv\Lib\site-packages` on `sys.path` itself, so the base interpreter
`C:\Users\emilo\AppData\Local\Programs\Python\Python313\python.exe` works too. Run everything from the scratchpad
directory (`SCRATCH`). The venv originally had no `python.exe`; it was restored with `python -m venv --upgrade luaenv`.

| File | Purpose |
|---|---|
| `check.py` | Syntax check + global read/write analysis via Lua 5.1 bytecode, plus the uniformity guardrail |
| `uniformity.py` + `uniformity_baseline.json` | Uniformity guardrail used by check.py (section 6); `test_uniformity.py` is its self-test |
| `look_diff.py` | Before/after comparison of `ui_audit.py --look` renders (section 7) |
| `luabc.py` | Lua 5.1 compiler wrapper + bytecode parser (used by check.py) |
| `known_globals.json` | Cache: globals/API fields/events read by 20 installed reference addons (`--rebuild-known`) |
| `harness.py` | `World` / `Client` simulator (Python side). `python tools\harness.py` = smoke run on real DisasterZone |
| `wowmock/mock.lua` + `core.lua objects.lua ui.lua game.lua` | The mocked client (Lua side, plain 5.1) |
| `wowmock/items.lua` | Item DB for every item in `Data/Items.lua` (generated) |
| `wowmock/items_fallback.json` | 23,576 other TBC items (lazy fallback for arbitrary item IDs) |
| `gen_items.py` | Regenerates the two item files + `items_report.json` |
| `test_harness_selftest.py` | Proves the harness works using only DisasterZone's `Libs/` |
| `example_scenario.py` | Copy-me template: 3 players, ML raid, boss kill, award, /reload on real DisasterZone |

---------------------------------------------------------------------------------------------------------------

## 1. `check.py` — static checker

```
luaenv\Scripts\python.exe tools\check.py                 # every .lua in DisasterZone except Libs/
luaenv\Scripts\python.exe tools\check.py Core UI\Council.lua   # files/dirs (relative to CWD or to the addon)
luaenv\Scripts\python.exe tools\check.py --libs          # include Libs/ when scanning directories
luaenv\Scripts\python.exe tools\check.py -q              # only ERROR lines + summary
luaenv\Scripts\python.exe tools\check.py --strict        # warnings also give exit code 1
luaenv\Scripts\python.exe tools\check.py --json          # machine readable
luaenv\Scripts\python.exe tools\check.py --rebuild-known # re-harvest known_globals.json (~10 s)
luaenv\Scripts\python.exe tools\check.py --uniformity    # per-file uniformity counts, worst first (section 6)
luaenv\Scripts\python.exe tools\check.py --uniformity-strict  # uniformity counts above the baseline are errors
luaenv\Scripts\python.exe tools\check.py --no-uniformity # skip the uniformity check
```

Output, one problem per line (`file:line: ...`), then a summary line:

| Line | Meaning |
|---|---|
| `ERROR syntax: <msg>` | `loadstring` (Lua 5.1) failed |
| `ERROR global write 'x'` | `SETGLOBAL` not in the allowlist: `DisasterZone`, `DisasterZoneDB`, `SLASH_DISASTERZONE*`, `BINDING_*`, `DisasterZone*` |
| `WARN _G write 'x'` | explicit `_G.x = ...` / `_G["x"] = ...` outside the allowlist |
| `WARN UNKNOWN GLOBAL 'x' (verify it exists on 2.5.x)` | read of a global no reference addon reads |
| `WARN UNKNOWN FIELD 'C_Foo.Bar'` | `C_*`/`Enum`/`Settings`/`MenuUtil`/`ScrollUtil`/`EventUtil`/`ChatFrameUtil`/... field no reference addon reads; also `string.x`/`table.x`/`math.x`/`os.x`/`bit.x` not in WoW's Lua (e.g. `table.unpack`, `os.getenv`). Works through `local C_Item = C_Item` aliases too. |
| `WARN DEPRECATED 'x' (hint)` | exists only behind deprecation fallbacks (`GetItemInfo`, `GetContainer*`, `GetAddOnMetadata`, `GuildRoster`, `GetLootMethod`, `SendAddonMessage`, `EasyMenu`, `InterfaceOptions_AddCategory`, ...) |
| `WARN NOT IN WOW 'io'` | `io`, `require`, `dofile`, `loadfile`, `module`, `package` |
| `WARN UNKNOWN EVENT 'X'` | `RegisterEvent("X")` string no reference addon registers/compares |
| `INFO OPTIONAL-DEP GLOBAL 'LBIS'` | global of an OptionalDeps addon (LoonBestInSlot): make sure it is nil-guarded |
| `WARN UNIFORMITY <kind>: <n> ...; baseline <m> (lines ...)` | a file has more literal token colours / local helper copies / numeric `SetFont` sizes / raid tables than `uniformity_baseline.json` allows (section 6); `ERROR` with `--uniformity-strict` |

Exit code: **1 if any syntax error or global write** (or any warning with `--strict`, or any uniformity count above
the baseline with `--uniformity-strict`), else 0.

How it works: each file is compiled with `loadstring(src, "@rel/path")` inside lupa, `string.dump`ed, and the
Lua 5.1 bytecode is parsed in Python (header sizes read from the dump: int 4, size_t 8, Instruction 4, number 8
on this machine). Nested prototypes are walked; `GETGLOBAL`(5)/`SETGLOBAL`(7) name constants come from `Bx`,
line numbers from the debug section. A `GETTABLE`/`SELF` with a constant key right after `GETGLOBAL`, or on a
local/upvalue whose name is a namespace (`local C_Timer = C_Timer`), records a field access.

Known globals = Lua 5.1 stdlib + WoW Lua extensions + every global **read** by LootReserve, Leatrix_Plus,
GudaBags, Auctionator/Source, WeakAuras, DBM-Core, Questie, Details, RaidHelper_TBC, LoonBestInSlot, RXPGuides,
TradeSkillMaster, AtlasLootClassic, Raidify, Raidify_Loot, TehBoxLootCouncil, ArmoryUtils, TBCRaidKompass,
PallyPower, NovaConsumesHelper (2,693 globals, 773 namespaces, 381 event names). `known_globals.json` stores
per-global the number of addons that read it. Refinements over "every read": a name an addon also *writes*, or
that starts with the addon's own prefix (`Questie*`, `WeakAuras*`, `DBM*`, ...), is not counted for that addon
(its own globals prove nothing about the client). Skipped: files that fail to compile (none do), files >1.5 MB
(data dumps: 46 Questie DB files, 10 RXP guide files, 1 TSM, 1 LootReserve), and lint stubs (`luaserver.lua`, or
>100 empty global functions — Details/luaserver.lua). `check.py` has a short hand-verified `EXTRA_KNOWN` list
(guild info text / rank / note APIs such as `GetGuildInfoText`, `SetGuildInfoText`, `CanEditGuildInfo`,
`GuildControlGetRankName`, and `C_ChatInfo.SendAddonMessageLogged`, `C_Timer.*`) that no reference addon happens
to read. "Known" only means some addon for this client reads it — it can still be guarded dead code there.

---------------------------------------------------------------------------------------------------------------

## 2. Mock client: writing a scenario

```python
import sys; sys.path.insert(0, r"...\scratchpad\tools")
from harness import World, Client, ExtraMember, LuaErrorsFound, LuaEvalError

w = World()                                        # realm "Thunderstrike"
a = Client(w, "Alice", guild_rank=1)               # PALADIN, guild "Casual Disaster", level 70, online
b = Client(w, "Bob", class_file="MAGE")
for c in (a, b):
    c.load_addon()                                 # DisasterZone.toc in order, ("DisasterZone", ns), login events
w.tick(2)                                          # virtual seconds; guild roster arrives at +0.5 s
w.make_raid([a, b], master_looter=a)
a.slash("/dz sync")
w.tick(10)
assert b.eval("return ns.Store:Get('Alice-Thunderstrike').rev") == 3
w.assert_no_errors()                               # raises LuaErrorsFound with all Lua tracebacks
print(w.report())                                  # warnings, unknown template fields/methods, missing globals
```

Each `Client` is its own `lua51.LuaRuntime`. Unit tests should call `w.assert_no_errors()` at the end: every
event/timer/OnUpdate/script/message dispatch runs in `xpcall` + `debug.traceback` and errors are only recorded.

### World

| Member | Notes |
|---|---|
| `World(addon_dir, realm="Thunderstrike", officer_rank=1, latency=0.1, guild_ranks=None, addon_throttle=True, onupdate_hidden=False, roster_delay=0.5, zone="Shattrath City", fail_fast=False, other_addons=())` | `fail_fast` = assert after every `tick()`/`load_addon()`; `other_addons` = names `IsAddOnLoaded` reports loaded |
| `tick(seconds=0.05, step=0.05)` | per step: deliver due messages, then per client: deferred events, internal timers, `C_Timer`, `OnUpdate(elapsed)` of **visible** frames, animations. `tick(0)` flushes deferred events |
| `run_until(pred, timeout=30)` | tick until `pred()` |
| `add_client(name, **kw)` | same as `Client(w, name, **kw)` |
| `make_raid(clients, master_looter=None, leader=None, assistants=(), extra_members=(), loot_method=None, loot_threshold=2)` | fires `GROUP_ROSTER_UPDATE` (+`PARTY_LOOT_METHOD_CHANGED`). Subgroups = 5 per group in list order. `extra_members`: names or `ExtraMember(name, class_file, realm, ...)` without a runtime |
| `make_party(clients)`, `disband()`, `set_master_looter(member)` | |
| `add_offline_member(name, class_file, rank, level=70, realm=None, public_note="", officer_note="")` | offline guild roster entry |
| `set_note(full_name, public=None, officer=None)`, `set_guild_info_text(text)`, `guild_info_text()` | |
| `enter_instance(name="Karazhan", instance_id=532, instance_type="raid", max_players=10, difficulty_id=3)` / `leave_instance()` | fires `PLAYER_ENTERING_WORLD(false,false)`, `ZONE_CHANGED_NEW_AREA` |
| `encounter(encounter_id, name, success=True)` | `ENCOUNTER_START`, `ENCOUNTER_END(id,name,diff,size,1/0)`, `BOSS_KILL` on group clients |
| `broadcast_loot_received(winner, itemID, count=1, give_item=False)` | `CHAT_MSG_LOOT` with `LOOT_ITEM_SELF(_MULTIPLE)` for the winner, `LOOT_ITEM(_MULTIPLE)` for the rest; returns `{full_name: text}` |
| `define_item(id, name, quality=4, equip_loc=..., class_id=15, subclass_id=0, ilvl=0)` | adds/overrides an item on all clients |
| `addon_log` | list of dicts: `time, sender, prefix, text (bytes), chat_type, target, logged, recipients, delivered, unregistered, dropped, error` |
| `chat_log` | SendChatMessage traffic (`sender, chat_type, text, target, recipients`) |
| `player_roll(who, value=None, lo=1, hi=100)` / `roll_log` | simulate `/roll` by a client, ExtraMember or name: every group client gets `CHAT_MSG_SYSTEM` "Name rolls N (lo-hi)" (`RANDOM_ROLL_RESULT`). Lua `RandomRoll(a,b)` in a client calls this automatically (seeded pseudo-random value) |
| `saved` | `{full_name: {svName: lua_source}}` |
| `errors()`, `assert_no_errors()`, `clear_errors()` | |
| `report()`, `report_warnings()`, `report_unknown_fields(lowercase=False)`, `report_unknown_methods()`, `report_missing_globals()`, `report_unknown_events()` | reports default to locations in the addon's own code (not `Libs/`); pass `addon_only=False` for all |

### Client

`Client(world, name, realm="Thunderstrike", class_file="PALADIN", guild="Casual Disaster", guild_rank=3,
online=True, level=70, race="Human", faction="Alliance", sex=2, talents=(41, 20, 0), legacy_globals=False,
permissive_fields=False, items_uncached=False, preload_lua=None, addon_dir=None, other_addons=(),
bank_requires_open=True, sv_before_files=None)`

* `legacy_globals=True`: define the deprecation-gated globals (`GetItemInfo`, `GetItemInfoInstant`, `GetContainer*`,
  `GetAddOnMetadata`, `GuildRoster`, `GetLootMethod`). Absent by default.
* `permissive_fields=True`: unknown frame fields return auto-created mock frames instead of nil.
* `items_uncached=True`: item queries return nil the first time and fire `ITEM_DATA_LOAD_RESULT` +
  `GET_ITEM_INFO_RECEIVED(id, true)` 0.1 s later (tests your async item code).
* `preload_lua`: Lua run after the mock is installed, before addon files (define stubs such as a fake `LBIS`).
* `guild=None` = guildless. `realm="Other Realm"` = cross-realm (normalized `OtherRealm`).

| Method / property | Notes |
|---|---|
| `load_addon(reload=False)` | parses `DisasterZone.toc` (+ `<Script>/<Include>` in XML), skips missing files with a warning, runs each file with `("DisasterZone", ns)`, assigns SavedVariables, fires `ADDON_LOADED("DisasterZone")`, `VARIABLES_LOADED`, `SPELLS_CHANGED`, `PLAYER_LOGIN`, `PLAYER_ENTERING_WORLD(true,false)` (`(false,true)` when reload) |
| `load_files([...], fire_login=False)` | load specific files (relative to the addon or absolute) |
| `relog(reload=True)` | fires `PLAYER_LEAVING_WORLD`, `PLAYER_LOGOUT`, serializes the SavedVariables to Lua source, builds a **fresh** runtime, `load_addon(reload=True)`. `reload=False` = full logout + login |
| `logout()` / `login()` | goes offline (guild sees `CHAT_MSG_SYSTEM "... has gone offline."`, roster update) / back online |
| `saved_variables()` / `set_saved_variable(name, lua_src)` | current serialization / pre-seed before `load_addon()` |
| `eval(code, *args)` | run Lua; `return` optional for expressions; `ns` = the addon namespace (also global `__NS`); `...` = args. Returns None / value / tuple, tables as lupa tables. Lua errors raise `LuaEvalError` with traceback. Non-UTF-8 strings come back as `bytes` |
| `eval_py(code)` / `to_py(luatable)` | deep-converted to dict / list (arrays with holes get `None`) / bytes; an empty table is `EmptyTable` (== `[]` and == `{}`) |
| `fire(event, *args)` | calls `OnEvent(frame, event, ...)` of every registered frame (dict/list args become tables) |
| `errors`, `warnings`, `printed`, `chat_frame`, `raid_notices`, `ui_errors`, `sounds`, `inserted_links`, `sent_addon`, `received_addon` | captured output (survives relog) |
| `open_loot([(itemID, quality[, count])], source_guid="Creature-0-1-2-3-15690-000ABC")` / `close_loot()` | `LOOT_READY(false)`, `LOOT_OPENED(false,false)` / `LOOT_CLOSED`. quality `None` = from DB |
| `start_loot_roll(itemID, quality=None, roll_id=None, roll_time=60000)` / `cancel_loot_roll(id)` | `START_LOOT_ROLL(rollID, rollTime)`, opens `GroupLootFrameN` |
| `equip({slot: itemID or None})` | `PLAYER_EQUIPMENT_CHANGED(slot, isEmpty)`, `UNIT_INVENTORY_CHANGED("player")` |
| `set_bags({(bag, slot): itemID or (itemID, count)})` | replaces bags 0-4; `BAG_UPDATE(bag)` + `BAG_UPDATE_DELAYED` |
| `set_bank({(-1 or 5..11, slot): itemID})`, `open_bank()`, `close_bank()` | `BANKFRAME_OPENED`, `PLAYERBANKSLOTS_CHANGED(slot)`, `BAG_UPDATE`, `BANKFRAME_CLOSED`. Bank contents are hidden while the bank is closed |
| `give_item(itemID, count=1)` | into the first free bag slot |
| `show_tooltip_item(itemID)` | `GameTooltip:SetOwner(UIParent)`+`SetItemByID` (runs `OnTooltipSetItem` hooks) → `[(left, right)]` |
| `accept_popup(which, text=None)` / `cancel_popup(which)` / `popups()` | StaticPopup OnAccept / OnCancel; `text` fills the edit box |
| `escape_popups()` | Escape in the game world: port of `StaticPopup_EscapePressed` (every shown `hideOnEscape` popup gets `OnCancel(dialog, data, "clicked")` unless `noCancelOnEscape`) |
| `set_ml_refusal(member, kind="inv_full")` | the server refuses this client's `GiveMasterLoot` to `member`: `UI_ERROR_MESSAGE` with `ERR_LOOT_MASTER_INV_FULL` / `_UNIQUE_ITEM` / `_OTHER` / `ERR_LOOT_PLAYER_NOT_FOUND`, the item stays in the slot; `None` accepts again |
| `last_menu()` / `menu_select(text)` / `dropdown_menu(frame)` | `MenuUtil.CreateContextMenu` / dropdown `SetupMenu` entries as `{kind, text, enabled, selected, children}`; select calls the callback / setSelected |
| `click(frame_or_name, button)`, `hover()`, `leave()`, `type_text(editbox, text, enter=False)`, `press_enter()`, `press_escape()` | UI interaction (OnClick incl. CheckButton toggle; OnTextChanged(self, true)) |
| `slash("/dz sync")` | runs the matching `SlashCmdList` handler |
| `frame(name)`, `dump_ui(frame=None, depth=6, textures=False)`, `find_text("substring")` | inspect the UI tree |
| `set_modifiers(shift, ctrl, alt)`, `set_combat(bool)`, `set_target(name)`, `set_cursor_item(id)`, `set_talents((a,b,c))`, `combat_log(*cleu_args)`, `define_item(...)` | |

---------------------------------------------------------------------------------------------------------------

## 3. What is mocked (and how faithfully)

Faithful where addon logic depends on it; permissive for visuals.

* **Messaging**: `C_ChatInfo.RegisterAddonMessagePrefix` (returns `Enum.RegisterAddonMessagePrefixResult`,
  `DuplicatePrefix`=1 on re-registration), `SendAddonMessage` / `SendAddonMessageLogged` (latency 0.1 s,
  returns 0). Prefix > 16 chars or text > 255 bytes **raise an error**. `RAID/PARTY` without group → 5
  (NotInGroup); `WHISPER` without target → 6; `GUILD/OFFICER` without guild → 9. Routing: GUILD = online
  same-guild clients incl. sender; OFFICER = rank ≤ `officer_rank` (sender must qualify); RAID/INSTANCE_CHAT =
  group; PARTY in a raid = own subgroup; WHISPER = `Name` or `Name-Realm` (case-insensitive), offline/unknown →
  dropped + `CHAT_MSG_SYSTEM "No player named 'X' is currently playing."`; SAY/YELL = everyone. Receivers need the
  prefix registered and get `CHAT_MSG_ADDON(prefix, text, chatType, "Name-Realm", target, 0, 0, "", 0)`;
  `...Logged` arrives as `CHAT_MSG_ADDON_LOGGED`. Per-prefix server throttle simulated (10 burst, +1/s →
  `AddonMessageThrottle`=3, message dropped) — ChatThrottleLib handles it; direct senders will see drops.
  Payloads are binary-safe (hex across the Python bridge). WoW's `xpcall(f, h, ...)` argument forwarding is
  emulated (ChatThrottleLib needs it).
* **Chat**: `SendChatMessage` / `C_ChatInfo.SendChatMessage` → `world.chat_log` and `CHAT_MSG_SAY/YELL/RAID
  (_LEADER)/RAID_WARNING/PARTY/GUILD/OFFICER/WHISPER` (+ `CHAT_MSG_WHISPER_INFORM`), sender `Name-Realm`.
  RAID_WARNING needs leader/assist and also goes to `RaidNotice_AddMessage`. >255 bytes errors.
* **Guild**: roster built from all clients + offline members, online first then by name. Empty until the first
  `GUILD_ROSTER_UPDATE` (auto 0.5 s after login, or next tick after `C_GuildInfo.GuildRoster()`).
  `GetGuildRosterInfo` returns 17 values; officer notes are "" unless `CanViewOfficerNote()` (rank ≤ 1).
  `SetGuildRosterShowOffline(false)` hides offline rows. Guild info text shared per guild, 500-byte limit, needs
  `CanEditGuildInfo()` (rank ≤ 1), fires `GUILD_ROSTER_UPDATE` for everyone whose roster is loaded. Notes are
  truncated to 31 bytes. Rank index is 0-based in the roster, `GuildControlGetRankName(i)` is 1-based.
* **Group**: `GetRaidRosterInfo` (12 values; name without realm for same-realm), `UnitInRaid` returns the 1-based
  raid index, `raidN/partyN/player/target/Name/Name-Realm` unit tokens, `C_PartyInfo.GetLootMethod()` →
  `(2, mlPartyID (0 = me), mlRaidIndex)`, `GetMasterLootCandidate(slot, i)` = online raid members in raid
  order, `GiveMasterLoot` → like WoW only a request: 0.1 s later the slot clears (`LOOT_SLOT_CLEARED` while the window
  is open) and the winner gets the item + everyone `CHAT_MSG_LOOT` 0.2 s after that, or (refusal knob) a
  `UI_ERROR_MESSAGE(0, ERR_LOOT_MASTER_*)` and the item stays. `IsModifiedClick()` without an action = any modifier;
  `HandleModifiedItemClick` is the classic_anniversary port (CHATLINK → `ChatFrameUtil.InsertLink`, DRESSUP).
  `StaticPopup_Show` cancels a reused dialog with `OnCancel(dialog, data, "override")` and, with all four busy, calls
  `OnCancel(nil, data)` and shows nothing (both as in Blizzard_StaticPopup).
* **Items**: `C_Item.GetItemInfo` (17 returns), `GetItemInfoInstant`, icon/quality/name by ID, `Item` mixin,
  `IsEquippableItem`, `GetItemCount`, links `|cffa335ee|Hitem:ID::::::::70:::::::::|h[Name]|h|r`.
  Non-equippable items report `INVTYPE_NON_EQUIP_IGNORE`. `GetItemInfo`-style calls error on nil/table args.
* **Frames**: widgets store state and fire scripts (`OnShow/OnHide` on visibility changes incl. parents,
  `OnClick`, `OnValueChanged`, `OnTextChanged`, `OnSizeChanged`, ...). `SetScript` of a script the widget type
  does not have (e.g. `OnClick` on a Frame) errors like WoW. `SetPoint` validates anchor names and self-anchoring.
  `SetBackdrop` only exists with `BackdropTemplate`. Unknown **methods** starting with a WoW verb (`Set`, `Get`,
  `Is`, `Enable`, `Register`, ...) are absorbed as no-ops and listed by `report_unknown_methods()`; unknown
  **fields** return nil and are listed by `report_unknown_fields()`. Templates with modelled children:
  BasicFrameTemplate(WithInset), Portrait/ButtonFrame/DefaultPanel templates, Inset/Dialog borders,
  UIPanelButton*, UIPanelCloseButton (hides parent), UICheckButton/InterfaceOptionsCheckButton/ChatConfigCheckButton,
  OptionsSliderTemplate, MinimalSliderWithSteppers, InputBox/SearchBox, UIPanelScrollFrame/FauxScrollFrame/
  ScrollFrameTemplate/InputScrollFrame, MinimalScrollBar, WowScrollBox(List), tab templates, UIDropDownMenuTemplate,
  WowStyle1DropdownTemplate (SetupMenu), ItemButton/LootButton/ActionButton, GameTooltipTemplate, BackdropTemplate.
  Unknown templates get generic children and a warning.
* **ScrollBox**: `SetDataProvider` (and every later Insert/Remove/Flush/Sort) runs the element initializer for
  **every** element with a real mock row frame (rows are reused by index, like pooling).
* **Other UI**: GameTooltip (+`TextLeftN` globals, `OnTooltipSetItem`, owner required), StaticPopups, MenuUtil,
  Settings (canvas/vertical categories, `RegisterAddOnSetting`), LibDBIcon/LibCustomGlow needs (pools, animation
  groups that finish after their duration, `Minimap`), `LootFrame`/`LootButton1-4` driven by the real
  `LootFrame_Update`/`LootFrame_UpdateButton` globals (hookable), `GroupLootFrame1-4`, `CharacterFrame` +
  `Character<Slot>Slot`, `SettingsPanel`, chat frames, `UIErrorsFrame`, `RaidWarningFrame`.
* **Time**: one virtual clock. `GetTime()` differs per client (separate bases, like different machines);
  `GetServerTime()`/`time()`/`date()` are shared. `os` only has `time/date/clock/difftime`; `io`, `require`, ... are
  removed. WoW string/table/math extensions (`strsplit` with char-set delimiters, positional `format("%2$s")`,
  degree-based `sin`, `bit.*`, `wipe`, ...).
* **Errors**: never swallowed. `geterrorhandler()` records too (AceComm/CallbackHandler/CTL use it). Load/syntax
  errors in addon files are recorded and loading continues with the next file (like WoW).
* **SavedVariables**: serialized to Lua source (nested tables, escaped strings incl. binary, integers up to
  2^53, floats `%.17g`, inf/nan, booleans; functions/userdata dropped; **recursive tables are an error**).
  WoW assigns SavedVariables **after** the addon's files ran, just before `ADDON_LOADED`, unless the TOC says
  `## LoadSavedVariablesFirst: 1` (DisasterZone's does, for in-game updates): then they are assigned before the first
  file. The mock follows the TOC; `sv_before_files=True` / `False` forces one order (`False` = a client that ignores
  the directive).
* **Other copies of the addon**: `World(addon_dir=...)` / `Client(..., addon_dir=...)` load another folder (the
  `tests/patch` suites build releases in a temp folder). The environment variables `DISASTERZONE_ADDON_DIR` and
  `DISASTERZONE_PATCH_SV` (a file with a `DisasterZonePatchDB` table) redirect every suite; `tools/patched_run.py` sets them.
* **Fault injection**: `world.addon_fault = fn(entry, recipient)` is called per recipient of every addon message;
  return `False` to lose it (listed in the entry's `lost`), bytes to replace its text, `None` to deliver.

### Assumptions (checked against installed addons where possible)

* `C_PartyInfo.GetLootMethod` returns Enum numbers (LootReserve/Leatrix compare with `Enum.LootMethod` / `2`).
* `UnitInRaid(unit)` is usable as `GetRaidRosterInfo(index)` (WeakAuras does this).
* `GetTalentTabInfo` modern order `id, name, desc, icon, pointsSpent, background, previewPoints, isUnlocked`
  (LoonBestInSlot/RXP/Details read `pointsSpent` as 5th). Tab IDs/names are TBC-like; `GetTalentInfo` returns nil.
* `CHAT_MSG_ADDON` 5th arg (target): recipient `Name-Realm` for WHISPER, `""` otherwise.
* `CHAT_MSG_LOOT`: arg2 = winner `Name-Realm`, arg5 = winner display name — parse the text, not the args.
* `RegisterAddonMessagePrefix` returns an enum (0 success) as on modern clients, not a boolean.
* The per-prefix addon-message throttle numbers (10 / 1 per s) and `SendAddonMessageResult` values 10-12.
* Deprecation-gated set (see `legacy_globals`); `GetItemIcon`, `GetItemCount`, `IsAddOnLoaded`, `GetSpellInfo`
  remain available (reference addons call them unguarded).
* The guild roster/info text is unavailable until the first `GUILD_ROSTER_UPDATE`; `GetGuildInfo("player")`
  works immediately.

### Known limitations

* No layout engine: `GetWidth/GetHeight` are what was set (or the parent's for `SetAllPoints`), `GetLeft/GetTop/
  GetCenter` are derived from size only, `GetStringWidth()` is `#text * 6`, nothing clips, no mouse hit testing
  (use `click()/hover()` helpers), animations only track duration.
* `OnUpdate` runs only for **visible** frames (as in WoW; ChatThrottleLib shows its frame while queueing). Use
  `World(onupdate_hidden=True)` to also run hidden frames.
* Performance: loading the real DisasterZone takes ~0.2 s per client; 10 clients x 60 simulated seconds tick in ~0.2 s.
* One group per World; everybody is in the same "zone" unless in the World's instance. `UnitX("Name")` resolves only
  the player and group members (as in WoW); `set_target(name)` can target any online client. No combat log/aura/spell
  simulation beyond `client.combat_log(...)`; `GetSpellInfo` returns placeholders; no real talent trees.
* Item quality and icons are synthetic (quality heuristic: raid loot = epic; icon = `130000 + id % 10000`; legendaries
  and the items cached in `review/data` carry their real quality / inventory type, see `fixer/fix_mock_items.py`);
  one-hand weapon slot (`INVTYPE_WEAPON` vs `WEAPONMAINHAND`) and ~18% of armor slots are heuristic (see below).
* Unknown-event checks use a harvested list; RegisterEvent never errors (the real client errors on invalid events).
* Tooltips have no stats/sets; `GetItemStats` returns `{}`. No inspect, no tree DataProvider, no secure templates
  behaviour, no protected-function taint (`InCombatLockdown` is a flag).
* Cross-realm realms are just names; there is no connected-realm logic.

---------------------------------------------------------------------------------------------------------------

## 4. Item data (`gen_items.py`)

`luaenv\Scripts\python.exe tools\gen_items.py` regenerates from local files only:

* 1,434 items = every ID in DisasterZone's `Data/Items.lua` (boss loot, tier tokens, tier pieces from `ns.Data.Tokens`,
  Sunmote upgrades, arena exchanges). Names: 100% from the `-- Name` comments.
* classID/subclassID/itemLevel/requiredLevel: 100% from `Questie/Database/TBC/tbcItemDB.lua`
  (`QuestieDB.itemKeys`: 9 itemLevel, 10 requiredLevel, 12 class, 13 subClass). No local source has
  inventoryType.
* equipLoc: 77.1% exact or from slot labels — 262 exact from class/subclass (2H/ranged/wand/thrown/shield/relic/
  non-equippable) + 843 from slot labels in `LoonBestInSlot/Guides/*.lua` and
  `AtlasLootClassic_TBC_Phase_*/*DB.lua`; 22.9% heuristic — 66 one-hand weapons (main-hand-only if only
  caster/healer BiS lists use it) and 263 armor/jewelry pieces by name keywords (mostly arena/tier pieces absent from
  BiS lists). Details: `wowmock/items_report.json`.
* `items_fallback.json`: every other TBC item in Questie's DB (same derivation, quality from item level), loaded
  lazily when an unknown ID is queried.

`items.lua` format: `[id] = {name, quality, equipLoc, classID, subclassID, icon, itemLevel, minLevel, bindType, stackCount}`.

---------------------------------------------------------------------------------------------------------------

## 5. Self-test and extending the mock

```
luaenv\Scripts\python.exe tools\test_harness_selftest.py        # -k <substring> to filter
```

13 tests (1-4 s): libs load; AceComm ~2 KB LibSerialize+LibDeflate+EncodeForWoWAddonChannel message over WHISPER
and GUILD through ChatThrottleLib (multipart reassembly, byte-exact, GUILD echo); raw routing/limits/throttle;
C_Timer; events/scripts/visibility/errors; widgets/templates/unknown-field log; ScrollBox/DataProvider/menus/
popups/Settings/dropdowns; TOC loading + relog/logout persistence; loot/ML/rolls/CHAT_MSG_LOOT; items/guild/
group/units/gear/bank/talents/tooltip hooks; LibDBIcon + LibCustomGlow; chat + slash commands; misc helpers
(hover/escape/modifiers/combat/target/combat log/define_item/logout notices/show-offline/legacy flag). It uses a
temporary addon folder containing only DisasterZone's `Libs/`, so it does not depend on the in-progress addon code.

Missing API? The run shows `attempt to call ... (a nil value)` in `errors` and the name in
`report_missing_globals()`. For a one-off stub use `Client(..., preload_lua="function Foo() return 1 end")`; for a
real addition edit `wowmock/game.lua` (game APIs), `ui.lua` (UI/templates), `objects.lua` (widget methods) —
keep plain Lua 5.1 (no `goto`, `//`, `table.unpack`) — and re-run the self-test.

---------------------------------------------------------------------------------------------------------------

## 6. Uniformity guardrail (`uniformity.py`, refactor 1.4 phase 1E)

Every normal `check.py` run also counts, per addon file, code that bypasses the shared design homes (comments and
string contents are ignored):

| Kind | What is counted | Home (not counted there) |
|---|---|---|
| `colour` | literal colour tuples equal to a `ns.Style` token: gold `1, 0.82, 0`, grey `0.62, 0.62, 0.62`, card `0.10, 0.10, 0.12`, edge `0.34, 0.34, 0.38` (any alpha), white hairlines/hovers `1, 1, 1, 0.0x`. Also found inside longer number runs (`Text(f, 10, 1, 0.82, 0)`, a gradient's two colours) | `UI/Style.lua` |
| `helper` | `local function X(` / `local X = function` for `Text newText Sized Gradient gradient Grad SlotLabel ShortName shortName classOf Hex grey Edge Fill NewCard BuildBanner NewChip Now DemoOn` | (none) |
| `font` | `SetFont(font, <number literal>...)` | `UI/Style.lua` |
| `raid` | a table constructor with 3+ raid keys of its own (`[532] =`, `Karazhan =`, `kara =`, ...) or a local named `INST_SHORT RAID_SHORT ART_TOP RAID_ART INST_ART ART_KEY INST_BY_ID` | `Data/Raids.lua`, `Core/ItemDB.lua` |

`uniformity_baseline.json` holds the counts per file (taken on release 1.3.5 + the 1.4 setup: 1,161 colours, 248
helpers, 47 font sizes, 30 raid tables). Only a count that goes **above** a file's baseline is reported, as
`WARN UNIFORMITY <kind>: <n> ...; baseline <m> (lines ...)`, so old code is quiet and the numbers can only fall.
A new file starts at 0.

```
luaenv\Scripts\python.exe tools\check.py --uniformity                 # table of counts, worst first, with the change vs the baseline
luaenv\Scripts\python.exe tools\check.py --uniformity UI              # the same for some files/dirs
luaenv\Scripts\python.exe tools\check.py --uniformity-strict          # counts above the baseline are ERRORs (exit 1)
luaenv\Scripts\python.exe tools\check.py --uniformity-update-baseline # rewrite the baseline (whole addon; with paths: only those files)
luaenv\Scripts\python.exe tools\check.py --no-uniformity              # skip it
luaenv\Scripts\python.exe tools\test_uniformity.py                    # self-test on fixture snippets (~2 s)
```

It stays warn-only while the refactor migrates pages; the cleanup stage refreshes the baseline after phase 3 and
switches to `--uniformity-strict`. When a migration lowers a file's counts, refreshing the baseline locks the gain in.

---------------------------------------------------------------------------------------------------------------

## 7. Render before/after (`look_diff.py`)

Compares two folders of `ui_audit.py --look` renders (PNG per view):

```
luaenv\Scripts\python.exe tools\ui_audit.py <new dir> -k "Raids - |Events - " --look
python tools\look_diff.py <baseline dir> <new dir> <out dir> [-k "View A|View B"]
```

For every view in both folders it measures the share of changed pixels and the mean change, writes `<out>/diff.md`
(worst first; views present on one side only are listed too) and, for each view that changed by more than 0.05 %,
`<out>/<view>.jpg`: baseline | new | changed pixels in red. `-k` filters by view-name substrings (spaces match the
underscores in file names). It needs Pillow only (no lupa). Open the JPGs and judge: intended unification is fine;
missing text, overlaps, clipped or empty areas, wrong layering or broken art are regressions. The refactor's
baseline renders (all 445 views of release 1.3.5) are in `C:\Users\emilo\DZ-wt\baseline_look`.
