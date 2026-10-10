# ShamanPower wire protocol (for interop)

Source read 2026-10-10: github.com/taubut/ShamanPower (main), files `ShamanPower.lua` and `ShamanPowerValues.lua`.
ShamanPower is **"All Rights Reserved"** (like Pally Power): DisasterZone only speaks its protocol; no code is
copied. Everything below is what goes over the wire. Items marked *unverified* were read from code summaries, not
tested against a running ShamanPower.

## Transport

- Prefix `SHPWR` (`ShamanPower.commPrefix`), registered with `C_ChatInfo.RegisterAddonMessagePrefix`.
- Sent through ChatThrottleLib `NORMAL`; channel `INSTANCE_CHAT` in an instance group inside an instance, else `RAID`,
  else `PARTY`; `WHISPER` with a target.
- Received only on `PARTY`, `RAID`, `INSTANCE_CHAT`, `WHISPER`; sender through `Ambiguate(sender, "none")`.
- ShamanPower drops repeats of the same text within 2 s, queues outbound (burst 10, then 1/s), holds ASSIGN-type
  messages during chat lockdown. It also listens to prefix `WFTracker` ("Name:Status:TimeRemaining", a WeakAura).
- Keyword = first word, `^(%u+)`. Unknown keywords are ignored (DisasterZone's `DZHERO` / `DZBOSS` rely on this).

## Indexes

Elements: 1 Earth, 2 Fire, 3 Water, 4 Air (WoW totem slots: Earth 2, Fire 1, Water 3, Air 4). 0 / `n` = none.

| | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| Earth | Strength of Earth 8075 | Stoneskin 8071 | Tremor 8143 | Earthbind 2484 | Stoneclaw 5730 | Earth Elemental 2062 | | |
| Fire | Totem of Wrath 30706 | Searing 3599 | Magma 8190 | Fire Nova 1535 | Flametongue 8227 | Frost Resistance 8181 | Fire Elemental 2894 | |
| Water | Mana Spring 5675 | Healing Stream 5394 | Mana Tide 16190 | Poison Cleansing 8166 | Disease Cleansing 8170 | Fire Resistance 8184 | | |
| Air | Windfury 8512 | Grace of Air 8835 | Wrath of Air 3738 | Tranquil Air 25908 | Grounding 8177 | Nature Resistance 10595 | Windwall 15107 | Sentry 6495 |

Defaults: Earth 1, Fire 2, Water 1, Air 1. Twist partner default: Air 2 (Grace of Air). Earth Shield 974 / 32593 /
32594 (Restoration 41-point talent).

## Messages

| Message | Format | Meaning |
|---|---|---|
| REQ | `REQ` | Everyone answers with SELF 0.5–2 s later |
| SELF | `SELF <earth>\|<fire>\|<water>\|<air>\|@<4 chars>#<hasES>:<ES target>$<free>` | Known totem indexes per element as digits (`n` = none), then the 4 assignments (digit or `n`), Earth Shield known 0/1 and its target, free assign 0/1. Example from the source: `SELF 123456\|1234567\|123456\|12345678\|@2512#1:Tankname` (the `$<free>` part per the summary, *unverified* whether always present) |
| ASSIGN | `ASSIGN <name> <element> <index>` | One element; 0 clears. Pattern `^ASSIGN (.+) (%d+) (%d+)$` |
| PASSIGN | `PASSIGN <name>@<4 chars>` | All four elements (`n` / empty = 0) |
| MASSIGN | `MASSIGN <name> <index>` | Same index for all four |
| TWIST | `TWIST <name> <0\|1>` | Windfury twisting on / off |
| ESASSIGN | `ESASSIGN\|<name>\|<target>` or `ESASSIGN <name> <target>` | Earth Shield target; `NONE` clears. (Replaced an older `ES_ASSIGN` that was never received.) DisasterZone sends the space form, reads both |
| CLEAR | `CLEAR` | From a leader: clears everyone; else the sender's own |
| FREEASSIGN | `FREEASSIGN YES\|NO` | Anyone may assign me |
| others | `WFBUFF 0/1`, `RESREQ/RESPASS/RESPICK`, `BLCALL/MTCALL/DRUMCALL`, `RCSYNC/MTSYNC/DRUMSYNC` | Not used by DisasterZone (raid cooldown calls, resist picks) |

Permissions (ShamanPower): ASSIGN / PASSIGN / MASSIGN / TWIST / ESASSIGN about another shaman are accepted from a
leader (raid rank > 0, or the party leader; nobody in instance groups) or when that shaman has free assign.

## DisasterZone extensions (same prefix, ignored by ShamanPower)

- `DZHERO <name> <pull|execute|call|none>`: when that shaman uses Heroism / Bloodlust.
- `DZBOSS <name> <bossKey> <element> <index> <alt 0/1>[@...]`: a totem that changes for one boss
  (`SerpentshrineCavern:Hydross`); alt 1 = the second one (right-click on the bar). Up to 5 entries per message.
- A leader's hello also sends every shaman's extras, so shamans without DisasterZone keep their boss changes.

## Unverified in game

- A real ShamanPower client reading our SELF (field order, the `$` part) and our ESASSIGN space form.
- ShamanPower's handling of our REQ answer timing (we answer one broadcast, it may whisper).
