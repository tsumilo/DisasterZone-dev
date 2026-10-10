# PallyPower Classic: reference for an interoperable re-implementation (TBC)

Source read: `C:\World of Warcraft\_anniversary_\Interface\AddOns\PallyPower` (version `v1.5.22-classic`, 2026-07-29).
Files: `PallyPower.lua` (4416 lines), `PallyPowerValues.lua`, `PallyPowerOptions.lua`, `PallyPower_TBC.xml`,
`PallyPower_TBC.toc` (Interface 20506), `Bindings.xml`, `locale\enUS.lua`, `LICENSE.txt`. Nothing was modified.

Line references without a file name are `PallyPower.lua`. `Values:N` = `PallyPowerValues.lua`, `Options:N` =
`PallyPowerOptions.lua`, `XML:N` = `PallyPower_TBC.xml`.

Labels used below:
- **(quirk)**: behaviour that looks like a bug in PallyPower, but we must stay compatible with it.
- **(inference)**: I worked this out from the code and WoW API behaviour. It is not stated in the code. Verify it in game.
- **(not in PP)**: general TBC knowledge that PallyPower does not contain. Verify it before relying on it.

---

## 1. License

`LICENSE.txt`: "Copyright (c) 2006-2012 Alexey Shmelev ... All Rights Reserved unless otherwise explicitly stated". This is proprietary: no copying or modifying. Only the localizations are "free for use", and the embedded libraries keep their own licenses. **We re-implement the wire protocol only and copy no code.**

---

## 2. Comm protocol

### 2.1 Transport

| Item | Value | Where |
|---|---|---|
| Addon prefix | `"PLPWR"` (the only one) | Values:3 |
| Prefix registration | `C_ChatInfo.RegisterAddonMessagePrefix("PLPWR")` at file load | Values:4 |
| Send API | `ChatThrottleLib:SendAddonMessage("NORMAL", "PLPWR", msg, chan[, target])` (CTL comes in with the embedded AceComm). The addon does **not** use AceComm serialization: messages are raw strings. | 1539, 1542 |
| Group channel picked | `INSTANCE_CHAT` when `IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and IsInInstance()`; otherwise `RAID` when `IsInRaid()`; otherwise `PARTY` | 1527-1536 |
| Whisper | `WHISPER` to `target` whenever a target is passed | 1538-1539 |
| GUILD | **Never used** for sending or receiving | - |
| Solo | Nothing is sent when `GetNumGroupMembers() == 0` | 1522 |
| Accepted on receive | prefix `PLPWR` and distribution in `PARTY`, `RAID`, `INSTANCE_CHAT` or `WHISPER` | 1591 |
| Sender name | `Ambiguate(source, "none")`, then `RemoveRealmName`: the realm is stripped when it equals your own `GetNormalizedRealmName()`, so same-realm senders arrive as a bare `Name` and others as `Name-Realm` | 1587, 1725, 2031-2038, 1563 |
| Own messages | ignored (`sender == self.player`). Messages are also ignored until `initialized` (set by the first `ScanSpells`). The one exception is `PPLEADER`, which is handled before this check. | 1727-1735 |

**Sending quirks (we must tolerate them, and copying them is optional):**
- **(quirk) Duplicate suppression:** `if lastMsg ~= msg then lastMsg = msg ... send` (1523-1524). The addon never sends a message that is byte-identical to the last one it sent, whatever the channel. So if two people send `REQ` in a row and the answer would be the same `SELF ...` whisper text, the second answer is dropped.
- **(quirk) The channel argument is ignored:** `local type` (1525) shadows the parameter, so the group channel is always computed. Only `target` (whisper) is honoured.
- There is no version-check message and no protocol version field.
- Throttling comes only from ChatThrottleLib at "NORMAL" priority, plus some timers:
  - Class-assignment sends are delayed 2.0 s (`C_Timer.NewTimer(2.0)` in `PerformCycle`, 990-1010). Each click creates its own timer, so this is not a real debounce; `lastMsg` collapses the repeats.
  - Single (normal) assignment sends are truly debounced at 2.0 s per `pally:class:target` key (429-445).
  - Aura assignment sends are delayed 2.0 s (4268-4277).
- **Max length:** 255 bytes per message (WoW limit). `NASSIGN` lists are chunked to 5 entries per message (1463-1472).

### 2.2 Shared data model (what the messages synchronise)

Every client keeps one copy of all paladins' data. These SavedVariables are global, so they are account-wide (toc).

```
PallyPower_Assignments[pallyName][classIdx]                  = blessingIdx (0 = none)        -- Greater ("class") blessings
PallyPower_NormalAssignments[pallyName][classIdx][targetName] = blessingIdx (nil/0 = none)    -- single-target override
PallyPower_AuraAssignments[pallyName]                        = auraIdx (0 = none)
AllPallys[pallyName] = { [1..6]={rank,talent}, AuraInfo={[1..8]={rank,talent}},
                         CooldownInfo={[1]=LoH,[2]=DI}, symbols, freeassign, subgroup }  -- runtime only
```

`targetName` is `GetUnitName(unit, true)`: `Name` for same-realm players, `Name-Realm` otherwise, and the pet's name for pets.

**Authority model:** every paladin's own `SELF` broadcast is the source of truth for that paladin's class assignments. Receiving `SELF` wipes `PallyPower_Assignments[sender]` and fully rewrites it (1755, 1771-1779). A leader's `ASSIGN` for paladin X changes everyone's copy, including X's copy, provided each receiver accepts it (section 2.5). If X's own client accepted it, X's next `SELF` carries the change.

### 2.3 Message catalogue (exact formats)

Notation: `<SP>` is one ASCII space. Index tables are in section 3.

| Msg | Exact format (sender code) | Sent when | Receiver action |
|---|---|---|---|
| **REQ** | `REQ` (354, 377, 1610, 1681) | Any client (non-paladins too), in a group: (a) 2 s after `GROUP_JOINED`; (b) opening the Blessings grid (`PallyPowerBlessings_Toggle`); (c) the grid Refresh button; (d) a known paladin left the group (`UpdateAllPallys`, 0.5 s delay) | 1741-1747: if `IsInRaid() and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and IsInInstance()`, call `SendSelf()` and broadcast. Otherwise call `SendSelf(sender)`, which **whispers** the reply to the requester, unless the requester is a leader, in which case it broadcasts. |
| **PPLEADER** | `"PPLEADER " .. self.player` (1395) | At the start of every `SendSelf` when the sender is a "leader" (raid leader, raid assist or party leader; see 2.5). Sent by non-paladins too. Always broadcast (no whisper target). | 1727-1733: `name` passes through `RemoveRealmName`. If `CheckLeader(name)`, sets the local flag `PP_Leader = true`, meaning "a leader in this group runs PallyPower". This affects who may Auto-Assign and how the Clear button behaves. |
| **SELF** | `"SELF " .. <12 chars> .. "@" .. <9 chars>` (1407-1435) | In `SendSelf` (paladins only, in a group). Broadcast, or whispered to a non-leader requester. | 1749-1780: parsed with `strfind(msg, "SELF ([0-9a-fn]*)@([0-9n]*)")`. Resets `PallyPower_Assignments[sender]={}` and `AllPallys[sender]={}` (this also drops AuraInfo, CooldownInfo, symbols and freeassign until the follow-up messages arrive). Creates `NormalAssignments[sender]` if it is missing but does **not** wipe it. Adds the sender to the grid (`SyncAdd`). |
| **ASELF** | `"ASELF " .. <16 chars> .. "@" .. auraIdx` (1436-1453) | Sent by `SendSelf` right after SELF, on the same channel or whisper | 1902-1925: sets `AuraAssignments[sender]=0`. Then, **only if `AllPallys[sender]` exists** (so SELF must come first), parses `"ASELF ([0-9a-fn]*)@([0-9n]*)"`, fills `AuraInfo[1..PALLYPOWER_MAXAURAS]`, and sets the aura assignment (`n` or empty means 0). |
| **NASSIGN** (list) | `"NASSIGN " .. table.concat(entries, "@")`, with each entry `format("%s %s %s %s", self.player, classIdx, targetName, blessingIdx)` and at most **5 entries per message** (1454-1473) | Sent by `SendSelf` after ASELF when the paladin has single assignments | 1816-1835 (see the single form below) |
| **NASSIGN** (single) | `"NASSIGN " .. pally .. " " .. classIdx .. " " .. targetName .. " " .. blessingIdx`, where `0` means clear (449-453) | 2 s debounce after a single assignment is changed to a **non-zero** value (418-446). Also: right-clicking a player name in the grid clears that player's overrides from **every** paladin and sends one message per paladin with value `0` (518-526). `LoadPreset` re-sends them all (3920-3930). | 1816-1835: iterates `string.gmatch(strsub(msg, 9), "([^@]*) ([^@]*) ([^@]*) ([^@]*)")`. For each entry the permission check runs on the entry's `pname`, and **the first entry that fails ends the whole message** (`return`). Then `NormalAssignments[pname][class+0][tname] = skill+0`, with 0 stored as nil. |
| **ASSIGN** | `"ASSIGN " .. pally .. " " .. classIdx .. " " .. blessingIdx` (1006, 1078); right-click clear: `"ASSIGN " .. pname .. " " .. class .. " 0"` (564) | Grid click or mouse wheel on a (paladin, class) cell, 2 s after the change (right-click clear is sent immediately). The class-button mouse wheel on the buff bar also sends it for yourself (XML:282-289). | 1782-1794: `strfind(msg, "^ASSIGN (.*) (.*) (.*)")` (greedy, so names cannot contain spaces). Checks permission, then `Assignments[name][class+0] = skill+0`. |
| **MASSIGN** | `"MASSIGN " .. pally .. " " .. blessingIdx` (994, 1066) | Shift+click or Shift+wheel on a grid cell: assigns one blessing to **all** classes | 1837-1850: `"^MASSIGN (.*) (.*)"`. Checks permission, then sets `Assignments[name][1..MAXCLASSES] = skill`. |
| **PASSIGN** | `"PASSIGN " .. pally .. "@" .. <9 chars>`, where each char is a blessing digit or `n` (3868, 3915) | **Auto-Assign** (after `CLEAR`, a 0.25 s delay, one message per paladin) and **Load Preset** | 1796-1814: `"^PASSIGN (.*)@([0-9n]*)"`. Checks permission, then rewrites `Assignments[name][1..MAXCLASSES]`. |
| **AASSIGN** | `"AASSIGN " .. pally .. " " .. auraIdx`; clear: `"AASSIGN " .. pname .. " 0"` (4218, 4273, 4296, 4410) | Aura cell click or wheel in the grid (2 s delay), Aura button wheel on the bar (for yourself), Auto-Assign auras | 1927-1938: `"^AASSIGN (.*) (.*)"`. Checks permission, then `AuraAssignments[name] = aura+0`. |
| **CLEAR** | `CLEAR` (332, 3852) or `CLEAR SKIP` (3898) | `CLEAR`: the Clear button when you are a leader, and the start of Auto-Assign. `CLEAR SKIP`: Load Preset. | 1886-1892: if the **sender is a leader**, calls `ClearAssignments(sender, skip)`, which clears greater and normal assignments for **all** paladins, and auras too unless the message contains `SKIP`. Otherwise, if the receiver's `opt.freeassign` is on, calls `ClearAssignments(self.player, skip)`, which clears only the receiver's own entries, or everything if the receiver is itself a leader **(quirk)**. |
| **FREEASSIGN / SYMCOUNT / COOLDOWNS** (combined) | `"FREEASSIGN " .. ("YES"|"NO") .. " | SYMCOUNT " .. symbolCount .. " | COOLDOWNS" .. <cdstr>` (1503-1517). `<cdstr>` is `":"..dur1..":"..rem1..":"..dur2..":"..rem2`, where a missing value is `n`; with no cooldown info at all it is `":n:n:n:n"`. | Last step of `SendSelf` (in a group) | Each part is matched **anywhere in the message**. `strfind(msg,"SYMCOUNT")` captures `"SYMCOUNT ([0-9]*)"` into `AllPallys[sender].symbols`, stored as a **string** unless it is "0" (1852-1861). `strfind(msg,"COOLDOWNS")` runs `strsplit(":", msg)`, ignores field 1, reads fields 2-5 as dur1, rem1, dur2, rem2, and computes `start = GetTime() - (dur - rem)` for each slot whose `rem ~= "n"`, but only if that slot is not set yet (1863-1884). `"FREEASSIGN YES"` / `"FREEASSIGN NO"` set `AllPallys[sender].freeassign` (1894-1900). All of these need `AllPallys[sender]`, so SELF must come first. |
| **FREEASSIGN** (bare) | `FREEASSIGN YES` / `FREEASSIGN NO` (XML:1913, 1916) | Toggling the "Free Assignment" checkbox in the grid | Same as above |

There is no "seal", "Righteous Fury" or "presets" message. Seal and RF are local only. Presets are applied by re-sending `CLEAR SKIP`, `PASSIGN` and `NASSIGN`.

**Order of a full `SendSelf` burst** (1390-1519): `PPLEADER` (only if you are a leader) → `SELF` → `ASELF` → `NASSIGN` x ceil(n/5) → `FREEASSIGN … | SYMCOUNT … | COOLDOWNS…`. Non-paladins send only the `PPLEADER` and stop there (1397-1399).

**When `SendSelf` runs:**
- `SPELLS_CHANGED` (bucketed 1 s; 1549-1559)
- `GROUP_JOINED` + 2 s (1606-1614)
- receiving `REQ`
- the grid opening or Refresh button
- `UNIT_SPELLCAST_SUCCEEDED` of Lay on Hands or Divine Intervention by any paladin unit, + 2 s (1689-1707)
- `PLAYER_ROLES_ASSIGNED` + 2 s, only if you are a leader (1709-1722)
- `UpdateAllPallys` re-discovery (1671-1686)
- the Clear button as a non-leader (337)

### 2.4 Field encodings

**SELF numbers block** (1407-1415): for blessing `i = 1..6` (TBC; the loop is `isWrath and 4 or 6`):
- if the blessing is unknown, `"nn"`
- otherwise `format("%x%x", rank, talent)`: 2 chars, rank and talent each as **one lowercase hex digit**

The receiver (1762-1770) **always loops 6** and decodes `rank = tonumber(c1, 16)` and `talent = tonumber(c2)`. The talent is decoded as **decimal**, which is harmless because talent values are at most 5. If the rank char is `"n"`, the blessing slot is left nil, meaning "cannot cast".

**SELF assignment block** (1416-1430): for class `i = 1..PALLYPOWER_MAXCLASSES` (TBC = 9), one char each: `n` when the class has no blessing, otherwise the blessing index digit (`1`..`6`). The receiver treats `n` or `""` as 0 (1771-1779).

**ASELF numbers block** (1437-1444): for `i = 1..PALLYPOWER_MAXAURAS` (TBC = 8), `"nn"` or `format("%x%x", rank, talent)`. After it comes `"@"` and the aura index as a decimal integer, 0 for none (1448). The receiver loops over **its own** `PALLYPOWER_MAXAURAS`.

**PASSIGN assignment block**: the same 9-char string as SELF's assignment block.

**Rank value:** the highest known rank, parsed from `GetSpellSubtext(GetSpellInfo(name))` with `"(%d+)"`. Unranked spells (Kings, Salvation, Concentration, Sanctity, Crusader) report `"1"` (1303-1317, 1325-1338). In TBC ranks go up to 8 (Might R8), which fits in one hex digit.

**Talent value:** see 3.6.

**Cooldown values** (1478-1501): `duration` and `remaining` come from `GetSpellCooldown(spellID)`, with `remaining = math.max(start+duration-GetTime(), 0)` (1369-1373). They are plain Lua `tostring` numbers, so `remaining` usually has decimals (for example `2875.123`). When the spell is ready, the API returns `0,0`, which is sent as `:0:0`. Slot 1 is Lay on Hands and slot 2 is Divine Intervention.

**symbolCount**: `GetItemCount(21177)` (Symbol of Kings), decimal (1386, 1475).

**Indexes in ASSIGN, MASSIGN, NASSIGN and AASSIGN** are plain decimal integers, with `0` meaning none or clear. Blessing `7` (Sacrifice) can appear **only in NASSIGN** (single assignments).

### 2.5 Permission model

"Leader" means `leaders[name] == true` (`CheckLeader`, 1955-1957). `UpdateRoster` fills that table (2215-2223):
- **in a raid:** anyone with `GetRaidRosterInfo` rank > 0, which is the raid leader (2) or an assistant (1)
- **in a party:** the party leader only (`UnitIsGroupLeader`, so rank 2)
- **in an instance group** (a battleground, `IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and IsInInstance()`): **nobody** is a leader

**Receive-side check** (ASSIGN 1785, PASSIGN 1799, NASSIGN 1819, MASSIGN 1840, AASSIGN 1930):
```
if name ~= sender and not (CheckLeader(sender) or self.opt.freeassign) then reject
```
So a change is accepted when one of these holds:
- it is the sender's own entry
- the sender is a leader
- **the receiver** has "Free Assignment" ticked **(quirk)**: the check uses the receiver's own flag, not the target paladin's flag, and the receiver then accepts edits to *any* paladin's entry

`SELF`, `ASELF`, `PPLEADER`, `REQ` and the `FREEASSIGN/SYMCOUNT/COOLDOWNS` message are accepted from anyone.

**UI-side check** (`CanControl`, 1943-1953), which decides whether you may edit a paladin in the grid:
- in an instance group: only `name == me`, or `AllPallys[name].freeassign == true`
- otherwise: true if `UnitIsGroupLeader("player")` or `UnitIsGroupAssistant("player")`; else `name == me` or that paladin's `freeassign == true`

The grid shows a paladin's name in white if you can control them, green if they are a leader, and red otherwise (647-655).

**Free Assign flag:** `opt.freeassign` is saved per profile, defaults to nil (off), and is set only by the grid checkbox (XML:1910-1918). It is advertised in every `SendSelf` (1505-1516). `AllPallys[me].freeassign` mirrors it (401-405, 1477).

**Auto-Assign / Clear gating:**
- `AutoAssign` runs only `if CheckLeader(me) or PP_Leader == false` (3849). That means a non-leader may auto-assign only when no leader in the group has announced PallyPower.
- `LoadPreset` is leader-only (3895).
- The Preset button is shown only to leaders (2588-2597).
- Clear as a non-leader clears only your own entries and re-sends `SELF`, and only `if not IsGuildMember(leader) or PP_Leader == false` (333-339).

### 2.6 Concrete TBC example messages

Paladin "Holypal": Blessing of Wisdom R7 with 2/2 Improved Blessing of Wisdom, Blessing of Might R8 with 0 talent, Blessing of Kings, Blessing of Salvation, Blessing of Light R4, no Blessing of Sanctuary. Greater Kings is assigned to every class except Hunters (6), who get none:
```
SELF 7280101040nn@33333n333
```
Prot paladin "Tankadin": Wisdom R7 0, Might R8 0, Kings, Salvation, Light R4, Sanctuary R5 with talent 1 (see 3.6). Greater Sanctuary for all classes. Auras: Devotion R8 with 5/5 Improved Devotion, Retribution R6 with 2/2 Improved Retribution, Concentration with 0/3 talent, Shadow/Frost/Fire Resistance R4, no Sanctity, Crusader. Assigned aura: Devotion.
```
PPLEADER Tankadin
SELF 708010104051@666666666
ASELF 856210404040nn10@1
NASSIGN Tankadin 1 Bigwarrior 3@Tankadin 4 Beartank 3
FREEASSIGN NO | SYMCOUNT 87 | COOLDOWNS:0:0:0:0
```
A leader's edits:
```
ASSIGN Holypal 2 2          -- Holypal: rogues get Greater Might
MASSIGN Holypal 3           -- Holypal: Greater Kings on all 9 classes
PASSIGN Holypal@112311111   -- full rewrite (Auto-Assign / preset)
NASSIGN Holypal 1 Bigwarrior 0   -- clear a single override
AASSIGN Tankadin 3          -- Concentration Aura
CLEAR SKIP                  -- preset load: clear blessings, keep auras
```
Lay on Hands on cooldown, 47 min 55 s left:
```
FREEASSIGN YES | SYMCOUNT 12 | COOLDOWNS:3600:2875.4130000001:0:0
```

---

## 3. ID tables (TBC branch: `isBCC`)

`PallyPower.isBCC = (WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC)` (4). The constants (Values:6-12) are:
- `PALLYPOWER_MAXCLASSES = 9`
- `PALLYPOWER_MAXPERCLASS = 15`
- `PALLYPOWER_MAXAURAS = 8`
- `petsShareBaseClass = true`

### 3.1 Class index (Values:147-156, ClassToID 180-189)

| idx | token | idx | token | idx | token |
|---|---|---|---|---|---|
| 1 | WARRIOR | 4 | DRUID | 7 | MAGE |
| 2 | ROGUE | 5 | PALADIN | 8 | WARLOCK |
| 3 | PRIEST | 6 | HUNTER | 9 | SHAMAN |

There is **no pet class in TBC**. Pets are listed under `UnitClassBase(petUnit)`, which is the class the game reports for the pet unit, so they share that class's Greater Blessing (Values:6, 2069-2095). Example: hunter pets are reported as WARRIOR **(inference / verify)**. The tooltip says "pets will appear under the respective class they share Greater Blessings with" (enUS:172).

- **Vanilla differs:** index 9 is `"PET"` (Values:166).
- **Wrath differs:** 10 = DEATHKNIGHT and MAXCLASSES = 10.

### 3.2 Blessing index (Values:330-340 normal, 348-356 greater)

| idx | Normal (`Spells`) | Greater (`GSpells`) |
|---|---|---|
| 0 | `""` (none) | `""` |
| 1 | Blessing of Wisdom (19742) | Greater Blessing of Wisdom (25894) |
| 2 | Blessing of Might (19740) | Greater Blessing of Might (25782) |
| 3 | Blessing of Kings (20217) | Greater Blessing of Kings (25898) |
| 4 | Blessing of Salvation (1038) | Greater Blessing of Salvation (25895) |
| 5 | Blessing of Light (19977) | Greater Blessing of Light (25890) |
| 6 | Blessing of Sanctuary (20911) | Greater Blessing of Sanctuary (25899) |
| 7 | Blessing of Sacrifice (6940): **single only**, never on yourself | - |
| 8 | `GetSpellInfo(425600)` "Horn of Lordaeron" (SoD). This is **nil in TBC**, so `#Spells == 7`. | - |

The tables store **localized names** from `GetSpellInfo(id)`; the IDs are only used to look up those names.

### 3.3 Rank tables: `{minTargetLevel, spellID}`, highest first (Values:364-387)

Normal:
- 1 Wisdom: {55,27142} {50,25290} {44,19854} {34,19853} {24,19852} {14,19850} {4,19742}
- 2 Might: {60,27140} {50,25291} {42,19838} {32,19837} {22,19836} {12,19835} {4,19834} {0,19740}
- 3 Kings: {10,20217}
- 4 Salvation: {16,1038}
- 5 Light: {59,27144} {50,19979} {40,19978} {30,19977}
- 6 Sanctuary: {60,27168} {50,20914} {40,20913} {30,20912} {20,20911}
- 7 Sacrifice: {60,27148} {52,27147} {44,20729} {36,6940}

Greater:
- 1 GBoW: {55,27143} {50,25918} {44,25894}
- 2 GBoM: {60,27141} {50,25916} {42,25782}
- 3 GBoK: {50,25898}
- 4 GBoSalv: {50,25895}
- 5 GBoL: {59,27145} {50,25890}
- 6 GBoSanc: {60,27169} {50,25899}

**How a rank is chosen for a target** (`CanBuffBlessing`, 1181-1250):
- **Target level >= 60:** use the unranked name (`Spells[id]` / `GSpells[id]`). Casting by name gets the highest known rank. Sacrifice on yourself becomes nil.
- **Lower-level target:** use the first entry with `IsSpellKnown(id)` and `UnitLevel >= minLevel`, written as `"Name(Rank N)"` from `GetSpellSubtext`. Kings and Salvation are written without a rank.
- **Greater blessings:** only when the target level is above 49.

### 3.4 Aura index (Values:426-436; icons 278-288)

| idx | Aura (spell ID in PP) | idx | Aura |
|---|---|---|---|
| 1 | Devotion Aura (465) | 5 | Frost Resistance Aura (19888) |
| 2 | Retribution Aura (7294) | 6 | Fire Resistance Aura (19891) |
| 3 | Concentration Aura (19746) | 7 | Sanctity Aura (20218), TBC/Vanilla only |
| 4 | Shadow Resistance Aura (19876) | 8 | Crusader Aura (32223) |

PP casts auras **by name only**, so the highest rank is used, and it keeps no table of aura ranks.
- **Wrath differs:** there is no Sanctity Aura, so Crusader is 7 and MAXAURAS = 7.
- **(not in PP)** TBC aura rank IDs, for reference:
  - Devotion: 465, 10290, 643, 10291, 1032, 10292, 10293, 27149
  - Retribution: 7294, 10298, 10299, 10300, 10301, 27150
  - Shadow Resistance: 19876, 19895, 19896, 27151
  - Frost Resistance: 19888, 19897, 19898, 27152
  - Fire Resistance: 19891, 19899, 19900, 27153

### 3.5 Seals, Righteous Fury, cooldowns, reagents

- **Seal index** (Values:403-415, local only, used by the RF/Seal button):

  | idx | Seal | idx | Seal |
  |---|---|---|---|
  | 0 | none | 6 | Command (20375) |
  | 1 | Justice (20164) | 7 | Vengeance (31801, Alliance) |
  | 2 | Light (20165) | 8 | Blood (31892, Horde) |
  | 3 | Wisdom (20166) | 9 | the Martyr (348700) |
  | 4 | Righteousness (21084), the default | 10 | Corruption (348704) |
  | 5 | the Crusader (21082) | | |

- **Righteous Fury:** `GetSpellInfo(25780)` (Values:389). Holy Light 635 is defined but never used.
- **Cooldowns** (Values:438-441):
  - [1] Lay on Hands: {633, 2800, 10310, 27154, 48788}
  - [2] Divine Intervention: {19752}
- **Reagent:** only **Symbol of Kings, item 21177**, counted with `GetItemCount(21177)` (1386). **Symbol of Divinity (17033) is not tracked.**

### 3.6 Talents read and how they are detected

`ScanTalents` (1287-1295) runs once in `OnEnable`. It maps every talent's **icon texture to {tab, index}**: `PallyPower_Talents[textureID] = {t, i}`.

`ScanSpells` (1297-1358) then reads `select(5, GetTalentInfo(tab, idx))`, the current talent rank, for the talent whose icon equals the spell's icon:
- **Blessings 1, 2 and 6 only** (Wisdom, Might, Sanctuary; 1311)
- **Auras 1, 2, 3 and 7 only** (Devotion, Retribution, Concentration, Sanctity; 1332)

Everything else gets talent 0. Nothing is detected by spell ID or by a fixed tab/index.

Expected TBC result **(inference; depends on icons matching)**:

| Slot | Talent that matches the icon | Range |
|---|---|---|
| Wisdom | Improved Blessing of Wisdom | 0-2 |
| Might | Improved Blessing of Might | 0-5 |
| Sanctuary | the *Blessing of Sanctuary* talent itself (same icon), which reads 1 whenever the spell is known | 1 |
| Devotion | Improved Devotion Aura | 0-5 |
| Retribution | Improved Retribution Aura | 0-2 |
| Concentration | Improved Concentration Aura | 0-3 |
| Sanctity | the Sanctity Aura talent and/or Improved Sanctity Aura; if two talents share an icon, the last one scanned wins | unclear |

**Kings is not talent-scanned** (in TBC it is a Protection talent spell). A re-implementation should use the same icon-match method, or produce identical numbers, so its SELF strings compare equally.

**Use of the numbers:** Auto-Assign scores Wisdom and Might paladins by rank + talent (3944-3968). The grid shows them as `"rank+talent"`, for example `7+2` (662-670).

### 3.7 Durations and refresh thresholds (Values:10-11)

| | TBC | Vanilla |
|---|---|---|
| Normal blessing (`PALLYPOWER_NORMALBLESSINGDURATION`) | 600 s (10 min) | 300 s |
| Greater blessing (`PALLYPOWER_GREATERBLESSINGDURATION`) | 1800 s (30 min) | 900 s |

Refresh thresholds:
- **Greater:** chosen for refresh when less than **600 s** remains (`minExpire = 600`, 3129, 3529).
- **Normal:** chosen when less than **240 s** remains (3205, 3619).
- **Sacrifice:** treated as `buffExpire = 270` so it rotates (3236-3239, 3647-3649), and as 30 s when "Buff Duration" is off (3261).

Righteous Fury and the seal timer both assume 30 min (2795, 2811).

---

## 4. Feature list (user-facing behaviour)

### 4.1 Blessings assignment grid (`PallyPowerBlessingsFrame`, XML; `PallyPowerBlessingsGrid_Update` 603-753)

Opened with the minimap left-click, `/pp blessings`, or a right-click on the drag handle. Opening it rescans, then sends `SELF` and `REQ` (360-382). Esc closes it (`UISpecialFrames`, 194).

**Top section: 9 class columns** (`ClassGroup1..9`):
- Each column has a class icon and up to **15** player names (`PlayerButton1..15`). Pets show a paw icon.
- A small icon next to a name shows **your** single-blessing override for that player (619-630).

| Action on a player name | Effect |
|---|---|
| **Left-click** | Opens a dropdown (455-516): "<name> can be assigned a Normal Blessing from:", then one submenu per paladin with "(none)" and each blessing that paladin can cast and that passes the target-level check. Paladins you cannot control are greyed out, and choosing for them does nothing. |
| **Right-click** | Removes that player's overrides from **all** paladins and sends `NASSIGN <pally> <class> <name> 0` for each (518-526) |
| **Mouse wheel** | Cycles **your own** override for that player through 0..7 (0..6 for yourself, since you cannot Sacrifice yourself), skipping blessings that `NeedsBuff` rules out unless Ctrl is held (1086-1115) |

**Bottom section: one row per paladin known through SELF** (`Player1..`), sorted by name (`SyncAdd`):
- the name, coloured by permission (2.5)
- Symbol of Kings count
- 6 blessing icons, each with `rank[+talent]`
- the first 3 auras (Devotion, Retribution, Concentration) with `rank[+talent]`
- Lay on Hands and Divine Intervention cooldown timers, or "Ready"
- one **aura cell** (`Aura1`)
- **9 class cells** showing that paladin's Greater Blessing icon

| Action on a class cell (550-586, 942-1084) | Effect |
|---|---|
| **Left-click** or **wheel down** | Next blessing the paladin knows (`CanBuff`) that `NeedsBuff` allows; after 6 it wraps to none |
| **Wheel up** | Previous blessing |
| **Shift** + click or wheel | Applies the blessing to all classes and sends `MASSIGN` |
| **Ctrl** + click or wheel | Ignores the "already given to this class by another paladin" rule |
| **Right-click** | Clear: sends `ASSIGN <pally> <class> 0` |

Only paladins you can control (`CanControl`) can be edited.

| Action on an aura cell (4207-4306) | Effect |
|---|---|
| **Click** or **wheel** | Cycles through auras the paladin knows |
| **Right-click** | Clear |

**Buttons:**

| Button | Behaviour |
|---|---|
| **Free Assignment** (checkbox) | Lets others assign you (2.5) |
| **Blessings Report** | See 4.8 |
| **Preset** (leaders only) | Click loads the stored preset; Shift-click stores the current assignments (3882-3942) |
| **Auto-Assign** | Shift-click uses the battleground templates (see 4.5) |
| **Options** | Opens the options window |
| **Clear** | See 2.3, CLEAR |
| **Refresh** | Rescans spells, cooldowns and symbols, then sends `SELF` and `REQ` |

There is also a scale grip: left-drag scales, right-click resets the scale to 0.9.

**`NeedsBuff` / Smart Buffs** (1252-1285):
- With `SmartBuffs` on (the paladin default), the cycle skips **Wisdom for Warriors (1) and Rogues (2)** and **Might for Priests (3), Mages (7) and Warlocks (8)**. **Hunters are not excluded in code (quirk)**: the exclusion was commented out at 1262, although the option text still says Hunters.
- It also skips a blessing another known paladin already gives to that class.

When a class-button wheel cycle wraps (`skipzero`), it defaults to Might for Warriors and Rogues, otherwise Wisdom (966-984).

### 4.2 Buff bar (secure buttons on `PallyPowerFrame`)

Shown only when all of these hold (2410, 2433, 2460, 2506):
- you are a paladin
- `opt.enabled` is on
- you are solo with `ShowWhenSolo` on, or in a group with `ShowInParty` on (this covers raids too)

Eight layouts (`Layout 1..8`, vertical or horizontal) set the button positions. Button size is 100x34. The drag handle `PallyPowerAnchor` works as follows (3474-3520):
- left-click locks or unlocks (it re-locks after 30 s)
- dragging moves the bar
- right-click toggles the grid
- Shift+right-click opens the options

**Class buttons `PallyPowerC1..9`:**
- There is one button per class present in the roster that has either your Greater assignment or at least one of your single overrides (2466-2469).
- Each shows the class icon, the Greater icon, a Greater timer (`Time`, the minimum over the class), a single-blessing timer (`Time2`) and the count of members missing a buff (`Text`).

Background colour (2718-2733):

| State | Colour | Default RGBA |
|---|---|---|
| nobody has the buff | `cBuffNeedAll` | red 1,0,0,0.5 |
| some missing the Greater | `cBuffNeedSome` | yellow 1,1,0.5,0.5 |
| only single overrides missing | `cBuffNeedSpecial` | blue 0,0,1,0.5 |
| all buffed | `cBuffGood` | green 0,0.7,0,0.5 |

The timer text colour runs from green to red according to remaining / duration.

Class-button clicks (attributes `type1` / `type2 = "macro"`):

| Click | Behaviour |
|---|---|
| **Left, out of combat** | `ButtonPreClick` (3324-3402) runs the "smart" pick (`GetUnitAndSpellSmart`, 3124-3299): an eligible class member with the lowest remaining Greater time under 600 s. It sets `macrotext1 = "/cast [@<Name>,help,nodead] <Greater Blessing of X[(Rank N)]>"`. |
| **Left in a raid, in combat** | `ButtonPostClick` (3404-3472), which runs out of combat after each click, builds a list of up to **9** class members who are in range, alive, not AFK and online. It then `WrapScript`s the button's `OnClick` with a restricted snippet that **rotates** `step1` through `unitNames` and sets `macrotext1` per click (3449-3467). This is the only way PallyPower casts greaters in combat. |
| **Right, out of combat only** | Smart pick of a single (normal) blessing: `macrotext2 = "/cast [@<Name>,help,nodead] <Blessing of X[(Rank N)]>"`. It is cleared in PostClick. |
| **Mouse wheel** | Cycles **your** Greater assignment for that class (it sends `ASSIGN`) |

Hovering a class button pops out its **player buttons** (secure `_onenter`, auto-hiding after 2 s, or 5 s when class buttons are hidden). It hides the other classes' popouts.

**Player popout buttons `PallyPowerC<c>P<p>`** (strata DIALOG; 2522-2562, 2841-2985):
- Each shows the name (with a paw for pets), the blessing icon, a timer, a range dot, a dead marker and a tank icon.
- The range dot is green when in range, yellow when visible but out of range, and red when not visible and out of range.
- Attributes are static, so these buttons **work in combat**:

| Click | Attributes / effect |
|---|---|
| **Left** | `type1 = "spell"`, `unit1 = <unitid>`, `spell1 = <greater spell string>` |
| **Right** | `type2 = "spell"`, `unit2`, `spell2 = <normal spell string>` |
| **Ctrl+Left, in a raid** | `ctrl-type1 = "maintank"`, `ctrl-action1 = "toggle"`: toggles the Blizzard **Main Tank** flag on that player |
| **Ctrl+Right** | `ctrl-type2 = "macro"`, `ctrl-macrotext2 = "/run PallyPower_NormalAssignments['<me>'][<class>]['<name>'] = nil"`: clears your override locally and **does not broadcast** |
| **Mouse wheel** | Cycles your single override for that player |

**Auto Buff button `PallyPowerAuto`** (a SecureActionButton with `type = "spell"`; 2268, 3522-3716):
- **PreClick** (`AutoBuff`, out of combat only) sets the `unit` and `spell` attributes for the best target. **PostClick** (`AutoBuffClear`) wipes them. In effect it **does nothing in combat**.
- **Left-click or `Hotkey2`: Greater.**
  - It scans every class, skipping units that have a single override (`specialbuff`).
  - Each unit must be in range of the greater (`IsSpellInRange == 1`) and alive.
  - If the unit holds only the normal version of the same blessing, that counts as 0 remaining.
  - In a raid, tanks with Salvation assigned are skipped, and so are units in combat when the class has a Main Tank.
  - It picks the class whose minimum `remaining + penalty` is lowest and below 600 s, and casts the greater on that class's best unit.
  - The penalty discourages re-picking the previously buffed unit while its buff is still above 600 s.
  - **Wait for Players** (`autobuff.waitforpeople`): a class is skipped when any member is connected and not AFK but not visible (`UnitIsVisible == false`). In a raid this applies only to classes with more than 3 members (3590-3592).
- **Right-click or `Hotkey1`: Normal.**
  - It scans the whole roster for units in range of the normal spell and alive.
  - It picks the lowest `remaining + penalty` below 240 s.
  - A unit holding a Greater with more than 240 s left gets a penalty and is skipped. A unit with a single override is rebuffed even when it has a Greater.
  - In a raid, tanks with Salvation assigned are skipped.

**Righteous Fury / Seal button `PallyPowerRF`** (2415-2432, 3755-3829):
- **Left** (`type1 = "spell"`, `unit1 = "player"`, `spell1 = <Righteous Fury>`): casts Righteous Fury, only when `opt.rf` is on.
- **Right** (`type2 = "spell"`, `spell2 = <selected seal>`): casts the selected seal.
- **Wheel** cycles the selected seal. **Shift+wheel** toggles `opt.rf`.
- Display: Righteous Fury timer (`Time1`) and seal timer (`Time2`). The background is red when both are missing, yellow when one is missing, green otherwise (3035-3061).
- **Hidden behaviour:** while Righteous Fury is up, `display.buffDuration` is turned off temporarily, which allows spamming greaters for threat (3043-3049).

**Aura button `PallyPowerAura`** (2438-2464, 4308-4376):
- Casts **your assigned aura** on click (`type1 = "spell"`, `unit1 = "player"`, `spell` attribute = the aura name).
- The wheel cycles your own aura assignment and sends `AASSIGN`.
- Two text lines list up to 2 other paladins **in the same subgroup** who have the same aura assigned (a conflict hint).
- Colour: red when the aura is not active on you, yellow when it is active but cast by someone else, green when you cast it.
- It is shown only if you know Devotion Aura (`AuraInfo[1]`).

**Update loop:**
- Bucketed events: `GROUP_ROSTER_UPDATE`, `PLAYER_REGEN_ENABLED`, `UNIT_PET` and `UNIT_AURA`, bucketed 1 s, call `UpdateRoster` (215).
- `UpdateRoster` calls `UpdateLayout` and then `ButtonsUpdate`.
- While any timer is showing, `ButtonsUpdate` repeats every 1 s (3065-3072).
- **`UpdateLayout` returns immediately in combat** (2377), so secure attributes and roster changes wait until combat ends.

### 4.3 Who needs a buff (no LibClassicDurations in TBC)

In TBC the native `UnitAura` is used. LibClassicDurations is used only when `isVanilla` (12-13).

Per unit (`ScanClass`, 2242-2263):
- `inrange = IsSpellInRange(normalName, unit) == 1`
- `visible = UnitIsVisible and UnitIsConnected`
- `dead = UnitIsDeadOrGhost`
- `hasbuff = IsBuffActive(normalName, greaterNameOfSameIndex, unit)`. This walks `UnitBuff(unit, j)` comparing the **localized buff name** to either name, and returns `expirationTime - GetTime()` (3301-3322).
- `specialbuff = (spellID ~= gspellID)`, meaning you have an override for this unit.

The effective blessing for a unit (`GetSpellID`, 3097-3110) is your override if one exists, otherwise your class Greater. Only **your own** assignments drive the bar.

States (2659-2673):

| State | Condition |
|---|---|
| `need_big` | missing, and no override |
| `need_small` | missing, and has an override |
| `have` | has the buff |

Exceptions (2688-2694): dead units in combat count as `have`. So do Salvation-assigned tanks missing Salvation, and units that are not visible while you are in combat.

### 4.4 Roster scanning, pets, tanks, Salvation

**Units scanned** (44-74, 2049-2240):
- in a party: `player`, `pet`, `party1-4` and `partypet1-4`
- in a raid: `raid1-40` and `raidpet1-40`

Each unit gets name `GetUnitName(u, true)` and class `UnitClassBase(u)`. In a raid, players also get `rank`, `subgroup`, `zone` and `role` from `GetRaidRosterInfo(n)` (field 10 is `"MAINTANK"` / `"MAINASSIST"`).

**Pets** (`ShowPets`, default on) are added under `UnitClassBase(pet)`, except:
- (a) non-hunter pets (GUID type other than `"Pet"`) with npcId 510 (Water Elemental), 19668 (Shadowfiend), 1863 (Succubus), 26125 (Risen Ghoul) or 185317 (Incubus)
- (b) any pet with buff 4511, which is Imp **Phase Shift** (2069-2095)

**Hide Bench** (`hideHighGroups`, raid only): hides players whose subgroup is above `ceil(maxPlayers/5)` for the current instance (2102-2110).

**Tank flag:** `tank = MAINTANK`, or `MAINASSIST` when `opt.mainAssist` is on (2112-2113). `classmaintanks[classIdx] = true` when the class has a MAINTANK (2203-2205).

**Main Tank / Main Assist auto-override** (raid only, options `mainTank` / `mainAssist`; 2115-2201):
- **Warriors (class 1):** if **your** Greater on the class equals `mainTankGSpellsW` (default 4 = Salvation), your single override for each Main Tank is set to `mainTankSpellsW` (default 7 = Sacrifice). The override is removed when the role goes away.
- **Druids and Paladins (classes 4/5):** the same, using `mainTankGSpellsDP` / `mainTankSpellsDP`. If the tank is you and the override would be Sacrifice, it is cleared instead.
- **Main Assist** works the same way with its own four settings.
- Auto-Assign applies the same overrides through `SetNormalBlessings` (4152-4191), and these are sent as `NASSIGN`.

**Salvation safety** (TBC/Vanilla only; option `SalvInCombat`, default off):
- **Static attributes:** in a raid, `spell1` and `spell2` are left empty when Salvation is the blessing for Warriors, Druids or Paladins (2538-2556).
- **Player buttons:** `PButtonPreClick` and `UpdatePButton` re-enable it out of combat, except Greater Salvation when that class has a Main Tank (2841-2927).
- **Class buttons** do the same (3367-3386, 3436-3444).
- **Auto Buff** skips Salvation on `unit.tank`.

**(quirk)** The per-unit check `k == unit.unitid` compares a number key with a string, so it never matches. Only the per-class Main Tank check works.

**Party, raid and solo:**
- **Solo:** no comms. The bar shows if `ShowWhenSolo` is on, and the roster is just you and your pet.
- **Party:** leader = party leader. Class buttons cast through the smart macro.
- **Raid:** leaders = raid leader and assists. The class-button greater rotation works in combat. Main Tank and Salvation logic is active. Report is allowed for leaders.
- **Battleground** (instance group): nobody is a leader, `REQ` answers are broadcast rather than whispered, Report is disabled, and Auto-Assign uses the BG templates.

**Group events:**
- `GROUP_JOINED` wipes `AllPallys` and the grid list, then sends `SELF` and `REQ` 2 s later (1596-1616).
- `GROUP_LEFT` wipes `AllPallys`, the grid list and **all** NormalAssignments. It deletes class assignments for paladins who are neither you nor in your guild (1618-1644).
- `UpdateAllPallys`: if a known paladin is no longer in the group, it re-discovers everyone (1646-1687).

**Periodic:** `ScanInventory` every 60 s counts Symbol of Kings (218). It is not broadcast until the next `SendSelf`.

### 4.5 Auto-Assign (3831-4205)

**Blessings:**
1. If you are a leader, or no leader runs PallyPower: clear your own entries, send `CLEAR`, then run `AutoAssignBlessings`.
2. Build lists of paladins per blessing, scored as follows (3944-3968):
   - Wisdom and Might: rank + talent
   - Kings, Salvation, Light, Sanctuary: rank
3. Re-rate the scores (4053-4077):
   - For each paladin whose Wisdom, Might, Kings or Sanctuary skill is above 1, lower that paladin's Salvation and Light scores by (skill - 1).
   - If the leader has Salvation in a raid (`PP_LeaderSalv`), raise the leader's Salvation score instead.
4. Pick a template by paladin count, capped at 6 (Values):
   - `BattleGroundTemplates`: in a BG, or with Shift (516-596)
   - `RaidTemplates`: in a raid (651-730)
   - `Templates`: in a party (785-865)
   - Each template is `[paladinCount][classIdx] = ordered blessing list`; 11 class entries exist but only 1-9 are used in TBC, and `0` means skip a slot.
5. For each class, walk the list and give each blessing to the best-scored paladin who is still free and **controllable**, until `paladinCount` slots are filled.
6. **In a raid, any paladin who gets Kings, Salvation, Light or Sanctuary (index > 2) gets it for every class** (4142-4145).
7. Main Tank / Main Assist overrides are applied.
8. After 0.25 s, send `PASSIGN <pally>@<9>` for every paladin.

**Auras:** after another 0.25 s (4378-4416), assign auras per **subgroup** in this order, highest rank then talent winning:
- in a raid: Fire, Devotion, Concentration, Retribution, Shadow, Frost, Sanctity, Crusader
- otherwise (or with Shift): Devotion, Concentration, Retribution, Shadow, Frost, Fire, Sanctity, Crusader

Each assignment is sent as `AASSIGN`. Only controllable paladins are considered.

`AssignPlayerAsClass` (1117-1169) exists but is never called.

### 4.6 Presets

- **Shift-click Preset** stores deep copies of all three assignment tables in `PallyPower_SavedPresets[...][0]`. There is a single preset slot.
- **Click** (leaders only) sends `CLEAR SKIP`, restores the copies, then 0.25 s later sends `PASSIGN` for each paladin, then 0.25 s later sends `NASSIGN` for every stored single assignment whose paladin is present (3882-3942).

### 4.7 Options (`PallyPowerOptions.lua`; defaults from `PALLYPOWER_DEFAULT_VALUES`, Values:14-73)

Non-paladins use the "Other" profile (Values:75-132), which turns most features off.

| Option key | UI label | Default (paladin) | Where |
|---|---|---|---|
| `enabled` | Enable PallyPower | true | Options:26-43 |
| `ShowInParty` | Use in Party | true | 44-60 |
| `minimap.show` | Show Minimap Icon | true (`minimapPos` 190) | 61-74 |
| `ShowWhenSolo` | Use when Solo | true | 75-91 |
| `ShowTooltips` | Show Tooltips | true | 92-108 |
| `ReportChannel` | Blessings Report Channel (0 = auto party/raid; otherwise an index into joined custom channels) | 0 | 109-127 |
| `SmartBuffs` | Smart Buffs | true | 139-152 |
| `ShowPets` | Show Pets | true | 153-166 |
| `SalvInCombat` | Salv in Combat | false | 167-181 |
| `buffscale` | PallyPower Buttons Scale (0.4-1.5) | 0.90 | 190-210 |
| `layout` | Buff Button / Player Button Layout (Layout 1-8) | "Layout 2" | 217-244 |
| `skin` | Background Textures (LSM) | "Smooth" | 245-264 |
| `border` | Borders (LSM) | "Blizzard Tooltip" | 271-290 |
| `configscale` | Blessing Assignments Scale | 0.90 | 291-311 |
| - | Reset Frames (execute) | - | 318-330 |
| `cBuffGood` / `cBuffNeedSome` / `cBuffNeedAll` | Fully / Partially / None Buffed colours | green / yellow / red, alpha 0.5 | 342-387 |
| `cBuffNeedSpecial` | (no UI) | blue 0,0,1,0.5 | Values:26 |
| `auras` | Aura Button | true | 417-430 |
| aura select | Aura Tracker (edits `PallyPower_AuraAssignments[me]` **without broadcasting**) | `opt.aura = 1` (unused) | 431-462 |
| `rfbuff` | Seal Button | true | 479-495 |
| `rf` | Righteous Fury | **nil** (off; not in defaults) | 496-512 |
| `seal` | Seal Tracker (0-10) | 4 (Righteousness) | 513-550 |
| `autobuff.autobutton` | Auto Buff Button | true | 567-580 |
| `autobuff.waitforpeople` | Wait for Players | true | 581-593 |
| `display.showClassButtons` | Class Buttons | true | 610-623 |
| `display.showPlayerButtons` | Player Buttons | true | 624-639 |
| `display.buffDuration` | Buff Duration (off = allow re-casting at will) | true | 640-655 |
| `display.enableDragHandle` | Drag Handle | true | 672-685 |
| `hideHighGroups` | Hide Bench (by Subgroup) | nil (off) | 706-719 |
| `mainTank` | Auto-Buff Main Tank | false | 733-746 |
| `mainTankGSpellsW` / `mainTankSpellsW` | Override Warriors ... with Normal ... | 4 / 7 | 747-811 |
| `mainTankGSpellsDP` / `mainTankSpellsDP` | Override Druids / Paladins ... | 4 / 7 | 812-876 |
| `mainAssist` | Auto-Buff Main Assistant | false | 877-890 |
| `mainAssistGSpellsW` / `mainAssistSpellsW` | (as above) | 4 / 7 | 891-955 |
| `mainAssistGSpellsDP` / `mainAssistSpellsDP` | (as above) | 4 / 7 | 956-1020 |
| `freeassign` | grid checkbox only | nil (off) | XML:1910 |
| `display.frameLocked`, `LockBuffBars`, `offsetX/Y`, `buttonWidth` 100, `buttonHeight` 34, `HideCountText`, `HideTimerText`, `HideRngText`, `HideDeadText`, `HideNameText` | no UI (internal) | see Values:29-44 | - |
| profiles | AceDBOptions | - | 101 |

### 4.8 Report, slash commands, keybindings, minimap

**Report** (841-940):
- With no channel set, you must be a leader in a party or raid; it is refused in BG instance chat. It sends:
  - `--- Paladin assignments ---`
  - then one line per paladin: `<Name>: <Blessing of X>, <Blessing of Y>`, using the **normal** spell names of the distinct greater indexes assigned, or `Nothing`
  - then `--- End of assignments ---`
- With `ReportChannel > 0`, it sends to `SendChatMessage(..., "CHANNEL", nil, chanNum)`.

**Slash commands:** `/pp` and `/pallypower` come from AceConfig (103). The GUI-hidden executes are `/pp blessings` (toggle the grid, refused in combat) and `/pp options` (open the options), plus `/pp profiles ...`. The settings, buttons and raid groups are `cmdHidden`.

**Keybindings** (`Bindings.xml`, category `PALLYPOWER_KEYCAT`):
- `AUTOKEY1` "Auto Normal Blessing Key"
- `AUTOKEY2` "Auto Greater Blessing Key"

They take effect through `SetOverrideBindingClick(autoButton, false, key, "PallyPowerAuto", "Hotkey1"|"Hotkey2")` (246-255).

**Minimap** (LibDBIcon / LDB "PallyPower", 141-171): left-click toggles the grid, any other click opens the options.

---

## 5. TBC-specific gotchas for our implementation

1. **Project detection.** All TBC tables depend on `WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC` (4). If an Anniversary client failed that test, PallyPower would fall into the **Vanilla tables**: class 9 = `PET` instead of SHAMAN, 5/15 min durations, 7 auras with no Sanctity, and LibClassicDurations. We should assume the TBC table, but sanity-check incoming data:
   - `SELF` always carries 6 blessing pairs and 9 class chars, regardless of mode.
   - `ASELF` carries 8 pairs in TBC and 7 in Vanilla or Wrath, so we should parse a variable length.
2. **Greater Blessings need a unit of the class.**
   - A Greater is cast on one member of a class and buffs every party or raid member of that class. Pets count under their game-reported class (`UnitClassBase(pet)`).
   - PallyPower always casts on a specific unit: `/cast [@Name,help,nodead] Greater Blessing of X` or `SecureActionButton unit=`.
   - Greaters consume **Symbol of Kings (21177)**. **(not in PP)** The Symbol of Divinity (17033) is for Divine Intervention and similar, not blessings.
   - Greater blessings need target level above 49. Every rank has a minimum target level; use the 3.3 table.
3. **Secure execution.**
   - Every cast is a secure attribute (`type`, `unit`, `spell`, `macrotext`) set **out of combat**.
   - In combat only the following work:
     - player popout buttons with static `spell1`/`spell2`
     - the class-button **WrapScript rotation** in raids, which steps through up to 9 names gathered before combat
     - the Righteous Fury, seal and aura buttons, which use static attributes
   - The Auto Buff button and the class-button "smart" macro do not work in combat.
   - `UpdateLayout` skips in combat, and `PLAYER_REGEN_ENABLED` triggers the refresh afterwards.
4. **Localized names.**
   - Spells are cast and buffs detected by **localized names** (`GetSpellInfo(id)`), and ranks are built as `Name(Rank N)` from `GetSpellSubtext`.
   - The wire protocol uses only indexes and numbers, so it is locale-independent. Player names are not: same-realm names are bare, cross-realm names are `Name-Realm`.
   - If our addon detects buffs by **spell ID** (`UnitAura` field 10), it must include every rank ID of both the normal and greater versions.
5. **Message-level quirks to tolerate when receiving:**
   - SELF must arrive before ASELF and FREEASSIGN, or those are ignored.
   - SYMCOUNT, COOLDOWNS and FREEASSIGN are matched anywhere in a message.
   - Cooldown numbers may be floats.
   - `talent` is decoded as decimal.
   - The first unauthorized NASSIGN entry aborts the rest of that message.
   - Identical consecutive outgoing messages are suppressed (the `lastMsg` dedupe), so do not rely on retries producing a duplicate.
   - **No traffic at all while solo.**
6. **Sending as an interoperable peer:**
   - To appear in PallyPower's grid you must send `SELF` (with `@` and 9 class chars), then `ASELF`, then the `FREEASSIGN … | SYMCOUNT n | COOLDOWNS:…` line.
   - Answer `REQ`. Whisper the requester unless they are a leader. In a raid inside an instance group, broadcast instead.
   - Leaders must send `PPLEADER <name>` so PallyPower users stop auto-assigning on their own.
   - Remember that **every** PallyPower client with Free Assignment ticked accepts your `ASSIGN`/`PASSIGN`/`NASSIGN`/`MASSIGN`/`AASSIGN`/`CLEAR` for any paladin. Otherwise they accept them only when you are a leader or the entry is your own.
7. **Clearing a single assignment is not broadcast in some paths.** `SetNormalBlessings(...,0)` only sends after 2 s if the value is non-zero (440). Ctrl-right-click on a popout clears only locally. Only a grid right-click on a name, or `LoadPreset`, sends `NASSIGN … 0`. Expect stale single assignments on peers and reconcile on the next `SELF`/`NASSIGN` burst. A `SELF` does not clear stale NormalAssignments.
8. **Sacrifice (7)** exists only for single assignments and never on yourself. Remote paladins are never `CanBuff(…,7)` because SELF carries only 6 pairs, so PallyPower offers Sacrifice only for the local paladin.
9. **Salvation and tanks** (TBC raid logic): avoid putting Salvation on Main Tanks. PallyPower's default MT override is "Greater Salvation, replaced by Blessing of Sacrifice" for Warriors, Druids and Paladins. `SalvInCombat` off blocks Salvation casts on classes that contain a Main Tank while those units are in combat.
10. **API details used in TBC:**
    - `IsSpellInRange(name, unit)` returns 1, 0 or nil, and PP compares it to `== 1`.
    - `UnitBuff` and `UnitAura` give real durations in TBC.
    - `GetRaidRosterInfo` field 10 gives the MT/MA role.
    - Toggling the Main Tank flag uses the secure `type = "maintank"`, `action = "toggle"`.
11. **Other minor quirks (harmless):**
    - `GetBuffExpiration` and `IsBuffActive` reference an undefined global `isWrath` and `gSpellName` (2757, 3302, 3306).
    - The Report channel test is always true (903).
    - The `NeedsBuff` player branch never runs (1268, `not pname == self.player`).
    - In `AutoBuff`, `classmaintanks[classID]` uses an undefined `classID` (3562).
