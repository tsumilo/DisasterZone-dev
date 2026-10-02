# DisasterZone 1.0.0

BiS lists, a Loot Council overview, boss-drop alerts and rolls for **&lt;Casual Disaster&gt;**.
For the WoW TBC Anniversary client (2.5.x, interface 20506).

- Every player keeps a best-in-slot list for each phase (P1–P5), with a main pick and an alt pick per slot, plus an optional off-spec list.
- The Loot Council sees everyone's lists. When a boss is looted, the council sees who has each drop on their list.
- Raiders get a Roll / Pass popup. Council members can vote for a player on any roll. DisasterZone suggests a winner, the council confirms it, and the award goes into a shared loot log with a reason (BiS, Alt, Offspec, Disenchant, ...).

DisasterZone only suggests. The council makes the loot decision.

---

## Contents

1. [Install and update](#install-and-update)
2. [Opening DisasterZone](#opening-disasterzone)
3. [Before the first raid](#before-the-first-raid)
4. [Quick start: Raider](#quick-start-raider)
5. [Raid sign-ups and teams](#raid-sign-ups-and-teams)
6. [Members tab](#members-tab)
7. [Quick start: Loot Council](#quick-start-loot-council)
8. [Quick start: Raid leader](#quick-start-raid-leader)
9. [Quick start: Guild Master](#quick-start-guild-master)
10. [How rolls pick a suggested winner](#how-rolls-pick-a-suggested-winner)
11. [Slash commands](#slash-commands)
12. [Settings reference](#settings-reference)
13. [Demo mode (try it solo)](#demo-mode-try-it-solo)
14. [FAQ and troubleshooting](#faq-and-troubleshooting)
15. [How it syncs, and privacy](#how-it-syncs-and-privacy)

---

## Install and update

**Requirements:** the TBC Anniversary client. DisasterZone has no required dependencies because every library it uses is built in.
**Optional:** LoonBestInSlot. If it is installed, My BiS shows a **Suggest** button that fills your list from its guides. Nothing else needs it.

### Install
1. Close the game.
2. Copy the `DisasterZone` folder into `World of Warcraft\_anniversary_\Interface\AddOns\`.
   The result must be `...\Interface\AddOns\DisasterZone\DisasterZone.toc`.
   The folder must be named exactly `DisasterZone`. Names such as `DisasterZone-main`, `DisasterZone (2)` or a folder nested inside another `DisasterZone` folder won't load.
3. Start the game. On the character screen, open **AddOns** and make sure DisasterZone is ticked.
4. In game, type `/dz` to check that it loaded.

### Moving from CDLoot
DisasterZone is the new name of CDLoot (from version 0.12.0). It is a new addon folder with its own saved data, so the first start copies your CDLoot data over.

1. Close the game. Copy the `DisasterZone` folder into `Interface\AddOns\`, next to `CDLoot`. **Do not delete `CDLoot` yet.**
2. Log in. A popup offers to import your CDLoot data. Click **Import + reload**.
3. DisasterZone copies everything (BiS lists, loot log, settings, games), switches CDLoot off and reloads. From then on only DisasterZone runs.
4. After that you can delete the `CDLoot` folder.

- The data is shared by the whole account, so one import covers every character. On another character where CDLoot is still ticked, the popup only offers to switch it off.
- Nothing is removed: `WTF\Account\<ACCOUNT>\SavedVariables\CDLoot.lua` stays as a backup.
- While CDLoot is switched on, DisasterZone does not run. The two never run together.
- Deleted `CDLoot` too early? Put the folder back, tick it, log in, and accept the import. If DisasterZone already has data of its own by then, `/dzpatch import` replaces it with the CDLoot data.
- Members who are still on CDLoot keep syncing with you until they move.

### Update
1. Close the game.
2. Delete the old `Interface\AddOns\DisasterZone` folder, then copy the new one in. Replacing the whole folder makes sure no old files are left behind.
3. Start the game and check the version with `/dz version`. The first line shows your own version.

### Updates that arrive in game
From version 0.10.0 most updates arrive by themselves. The person who publishes an update sends it over the guild's addon channel; your client downloads it in the background, checks its signature and stores it.

- When an update is ready, a popup asks to reload the interface. **Reload** applies it. **Later** is fine: the next `/reload` or login applies it.
- The popup never appears in combat or during a boss fight, and nothing changes before you reload.
- Only updates signed by the publisher are accepted, whoever relays them.
- An update with new art (maps, Azeromon zones) still needs the download above. You get the rest of that update in game, and a chat line tells you there is new art to download.
- `/dz update` shows your version and the download progress. `/dzpatch off` turns in-game updates off, `/dzpatch on` back on, and `/dzpatch rollback` goes back to the version you installed.
- If an in-game update fails to load, DisasterZone switches it off, stays inactive until you click **Reload**, and then runs the version you installed.

Your data is safe when you update. Your lists, settings and the loot log are stored in
`WTF\Account\<ACCOUNT>\SavedVariables\DisasterZone.lua`, not in the addon folder. That file is shared by every character on the account. Each character still keeps its own BiS list.

Everyone should run the same version. See [Mixed versions](#mixed-versions).

---

## Opening DisasterZone

| How | What it does |
|---|---|
| `/dz` or `/disasterzone` | Opens or closes the DisasterZone window (it opens on Home) |
| Minimap button | Left-click opens the window. Right-click opens Settings. Shift-click opens the boss drop panel. |
| Game Options → AddOns → DisasterZone | **Open DisasterZone settings** |

The window has these tabs:

| Tab | Who sees it |
|---|---|
| **Home** | Everyone: what needs you now, the next raid (sign up in one click), your BiS picks that can drop there, recent loot, and a readiness check for the council and raid leaders |
| **My BiS** | Everyone |
| **Council** | Loot Council members (and anyone in demo mode) |
| **Loot Log** | Loot Council members (and anyone in demo mode) |
| **Raids** | Everyone in a guild (the Raid log view: council, Guild Master and raid leaders) |
| **Games** | Everyone |
| **Settings** | Everyone |
| **Changelog** | Everyone: what changed in each version |

The window opens on Home. To open it on the tab you used last instead, pick **Settings → Main window → Open on**.
When a new version is installed, Home shows a **What's new** chip until you read its notes.

The top-right of the window shows your list's sharing status. See [Sync status](#what-does-the-sync-status-mean).

---

## Before the first raid

- [ ] **Everyone** has the same DisasterZone version. The raid leader checks with `/dz version`.
- [ ] **Everyone** has filled in their My BiS list for the current phase, and the status says "Shared with council".
- [ ] **Guild Master** has picked the guild council and the guild phase (see [Guild Master](#quick-start-guild-master)).
- [ ] **Raid leader** has set the group loot rules and, if wanted, extra raid council members (see [Raid leader](#quick-start-raid-leader)).
- [ ] **Master looter** has set the loot method to Master Looter if DisasterZone should hand items out.
- [ ] **Everyone** has BugSack installed so any Lua error can be reported (see [Reporting a Lua error](#reporting-a-lua-error)).

---

## Quick start: Raider

### 1. Build your list (My BiS tab)

The top bar holds these controls:

- **P1 … P5**: which phase you are editing. A small star marks the guild's current phase. If your group's loot leader set a raid phase, it marks that phase instead.
- **Main spec** / **Off spec**: which of your two lists the tab shows. See [Off-spec list](#7-off-spec-list).
- **Spec**: pick your spec, or choose **Auto-detect** to use the talent tree with the most points.
- **Copy from ▾**: copy another phase into this one, using **Copy Pn (fill empty)** or **Copy Pn (overwrite)**. It also offers the same phase of your other list, e.g. **Copy main spec Pn**.
- **Suggest ▾** (only shown when LoonBestInSlot is installed): **Fill empty slots from LoonBestInSlot (spec Pn)**, or **Replace all (confirm)**. You must choose your spec first.
- **Clear phase**: removes every pick in this phase. It asks first.

Below the top bar is a paper doll with all 17 slots. Each slot has a **main** pick (the large icon) and an **alt** pick (the small icon next to it).

- **Click a slot** to open the item picker for that slot.
- **Click the small alt square** (it shows a "+" while empty) to choose an alt. An alt is a backup or upgrade-path item for that slot.
- **Drag an item from your bags onto a slot** to use any item, including items the picker doesn't list.
- **Shift-click** an icon to link the item in chat.

### 2. The item picker

The picker opens next to the window. Its title reads, for example, "Choose Head (Main) · P2".

- **Search**: matches item names, bosses, professions, factions, vendors and seasons.
- **Phase filter**: **Up to Pn** (the default), **Only Pn**, or **All phases**.
- **Sources ▾**: a checklist of **Raids**, **5-man dungeons**, **Crafted**, **Reputation**, **Badge vendors** and **PvP**.
  - The default is Raids + 5-man dungeons. Your choice is remembered.
  - **Reset to raids + 5-man dungeons** restores the default.
  - PvP items and faction-only reputation items are shown for your own faction only.
- **Usable by my class** is on by default. It also hides items that only other classes can use, such as class trinkets, Medallions and PvP set pieces.
- **My armor type only** is on by default and only appears on armor slots.
- Each item row shows where it comes from, for example "Blacksmithing (375)", "The Sha'tar — Exalted" or "G'eras — 60 badges". Heroic-only dungeon items carry a **Heroic** tag. Class-restricted items also name their classes, for example "Rogue".
  - "Main" or "Alt" on the right means the item is already on this phase's list.
  - "owned" means you already have it.
- **Tier pieces** are listed under the boss that drops the token and show "via *token name*". Pick the piece you want, not the token.
- **Clear** (next to the current pick) empties the slot.
- To use any other item, shift-click its link while the picker is open, or drag it from your bags onto the picker.

The picker won't open while the raid leader has [locked the lists](#lock-and-unlock-bis-lists).

### 3. Right-click a slot for more options

| Menu entry | What it does |
|---|---|
| **Choose main...** / **Choose alt...** | Opens the picker |
| **Swap main / alt** | Swaps the two picks |
| **Mark obtained** / **Mark not obtained** | Sets the obtained state by hand, for the main pick |
| **Clear slot** | Removes both picks |
| **Link main in chat** | Links the main pick |
| **Disable slot (Pn)** / **Enable slot (Pn)** | Disables the slot in this phase |
| **Disable in all phases** / **Enable in all phases** | Disables the slot in every phase |

### 4. Disabling a slot

Disable a slot you don't need in a phase. For example, disable the off hand if you use a two-hander, or a slot you have already filled for good.

- The slot turns grey and reads "Disabled — not needed".
- It is left out of your progress ("x / 16"), the council's need counts and drop alerts.
- Your picks for that slot in earlier phases stop counting too.
- Your pick is kept. Click the slot to enable it again.

### 5. Obtained detection

DisasterZone marks a pick as obtained on its own when the item is:

| State shown | When |
|---|---|
| **Equipped** | You wear it |
| **In bags** | It's in your bags |
| **In bank** | It's in your bank. This is only updated while your bank window is open, so visit the bank once. |
| **Have token** | You hold a tier token or quest item that turns into it |
| **Marked obtained** | You set it with **Mark obtained** |

The centre card shows "Pn · x / 17 obtained" above your character model dressed in the phase's BiS picks (drag to rotate). Empty or disabled slots, and picks that can't be worn such as tier tokens, show what you have equipped.

### 6. Sharing

You don't need to do anything to share your list.

- Changes are sent to online council members about 8 seconds after your last edit, or as soon as you close the window.
- The **Sharing** line on the card and the text at the top-right of the window show the status. See [Sync status](#what-does-the-sync-status-mean).

### 7. Off-spec list

Next to your main-spec list you can keep one **off-spec** list, for example tank gear as a Fury warrior or healing gear as a Retribution paladin.

- Click **+ Off spec** in the top bar. The button reads **Off spec** once you have one. **Main spec** switches back.
- Choose the off spec in the **Spec** dropdown, then pick items as usual. Everything on the tab (the slots, the picker, **Copy from**, **Suggest**, **Clear phase**, disabling slots and the progress card) works on the list that is shown.
- **Copy from ▾ → Copy main spec Pn** fills the off-spec list with your main-spec picks for shared slots such as rings, trinkets and cloaks.
- To delete it, choose **Remove off-spec list...** in the off spec's **Spec** dropdown. It asks first.

How the council uses it:

- Off-spec wanters are listed **after** everyone who has the item on their main-spec list, with an **[OS]** badge.
- In a roll, an off-spec pick ranks after main-spec BiS and main-spec alt picks, but before players who don't list the item.
- Winning an item through your off-spec list is recorded as **Offspec**, so it doesn't count as loot received.
- When an off-spec item drops you get a lighter toast, "On your off-spec list (Protection)". Turn it off in Settings → **Alerts for off-spec list items**.

### 8. Alt characters

Every character has its own list. Log in on the alt and fill in its My BiS tab. It is shared under that character's name.

### 9. When loot drops

You'll see these when one of your needed picks drops:

- **Toast:** "On your BiS list!" with the item's icon, the slot, the phase and whether it's your main or alt pick. Click it to link the item. Right-click it to dismiss it.
- **Chat line:** "[item] is on your BiS list: Head, P2 (main)".
- **Loot window:** your item shows a **Yours** badge and a glow.

### 10. The roll popup

When the council starts a roll, a popup appears.

- The top line shows the item and your status for it: "Your P2 BiS (main) - Head", "Your P3 alt - Ring 1", "Your P2 off-spec BiS (Protection) - Main Hand" or "Not on your BiS list".
- **Wearing:** shows what you have equipped in that slot. For rings, trinkets and weapons it shows both.
- A countdown shows the time left.
- **Roll** does a normal `/roll` (1-100). **Pass** passes.
- Afterwards the popup shows "You rolled 87", "Passed", "Rolls closed", then "Won by Name" or "You won it!". It fades 5 seconds after the item is awarded.

A few rules:

- Typing `/roll` in chat counts too, so players without DisasterZone can still roll.
- Only a 1-100 roll counts, and only your **first** roll counts.
- Only one item is rolled at a time. The others wait in a queue.
- If you win an item after the popup has moved on to the next one (for example during **Roll all**), chat tells you "You won [item]!".

### 11. Tooltips

Item tooltips show your own status. For example:

- "DisasterZone ★ Your P2 BiS (main) - Head"
- "Your P3 alt - Ring 1", with "obtained" when you already have it
- "also P3, P4" when the item is on other phases too

### 12. When lists are locked

During a raid the raid leader can lock everyone's lists. While locked:

- My BiS shows a banner, "BiS lists locked by *name*".
- You can't change picks, spec or disabled slots.
- Items you get, and **Mark obtained**, still update and still sync.

---

## Raid sign-ups and teams

Raids are planned in the **Raids** tab. Everyone in the guild has it.

### Signing up (everyone)
1. Open the **Raids** tab (or type `/dz raids`). **Upcoming** lists the raids of this week, next week and later.
   Raids you still have to answer have an orange bar and "you: not answered".
2. Pick a raid. Under **Your answer**, click **Accept**, **Tentative**, **Bench** or **Absent**.
3. Pick your **spec** in the dropdown next to the buttons. It is remembered for your next sign-up. You can add a short
   **Note** (for example "late 20 min", press Enter to save).
4. You can change your answer at any time until 6 hours after the raid started.

The raid shows who is coming, sorted into **Tanks / Healers / Melee / Ranged**, followed by Bench, Absent and the
invited members who haven't answered ("No response"). When you log in, DisasterZone reminds you in chat of the raids of
your teams in the next 7 days that you haven't answered.

### Who can do what
| | Plan raids | Build teams | A raid's groups, Invite & sort | Pick raid leaders |
|---|---|---|---|---|
| Guild Master | yes | yes | yes | yes |
| Officers (the rank below the GM) | - | - | - | yes |
| Guild council | - | yes | yes | - |
| Raid leaders | yes | - | yes | - |

With nobody on the raid leaders list, only the Guild Master plans raids.

### Raid leaders (officers)
Officers can name **raid leaders**: players who run raids but aren't loot council. Open **Raids > Teams >
Raid leaders**, add them with the search box and click **Save & share**. Everyone can open the window to see who they
are.
- Raid leaders plan raids, arrange a raid's groups and use Invite & sort. They see the **Raid log** (attendance,
  bench, no-shows), but not which items were awarded.
- They get no loot council access: no Council tab, no other players' BiS lists, no drop panel or votes, no Loot Log.
  (Like anyone, they are loot council for the raid they are leading at that moment.)

### Planning raids (Guild Master and raid leaders; teams: Guild Master and guild council)
- **Teams**: in the **Teams** view, click **New team**, type a name, add guild members with the search box and click
  **Save**. A player can be on several teams.
- **New raid** (Upcoming view): pick the raid, size, day and time, the teams it is for (none = everyone), an optional
  title (e.g. "Gruul + Mag") and note. Tick **Repeat weekly** for a raid that happens every week: the next two weeks are
  always planned automatically.
- **Edit** changes a raid. For a weekly raid you choose **This week only** or **Save every week**. Sign-ups are kept.
- **Cancel...** cancels this raid (it stays listed as cancelled and can be restored) or stops a weekly raid after this
  week.
- The red **delete** button next to Edit removes the raid for everyone, with its sign-ups and groups, after you confirm.
  For a weekly raid you pick this week's raid only or the whole weekly raid.
- An open raid is seen by everyone and anyone can sign up. The teams decide who gets the reminder and who is listed
  under "No response".
- **Locked** (a checkbox in the New raid / Edit window): only the members of the raid's teams and the invited players
  can sign up, and only they (plus the Guild Master, the guild council and the raid leaders) see the raid.
- **Invite** (the button next to Edit, or the Invite box in the raid window) adds players outside the teams to a raid.
  From the button, a weekly raid changes for this week only.

### Strategy boards (everyone)
- **Raids > Strategies** lists every strategy. Click a raid or a boss on the left to narrow the list, type in the
  search box (strategy, boss, raid, builder or table name), or pick a guild member under **By**.
- **New strategy** builds one for a boss. It is yours: only you change it.
- **Share** invites guild members to change your strategy with you, and takes them off again.
- **Copy** makes any strategy yours. The Guild Master and the guild council can edit and delete any strategy.
- Who does what in a raid (the Assignments tab of a raid) is filled in by the Guild Master, the guild council and the
  raid leaders.

### Team groups (Guild Master and guild council)
- In **Teams**, pick the team's size (10 / 25) and place members in groups: drag a name into a group, or click it and
  then click a group. Drop onto someone to swap places. **Auto-fill** makes a starting layout (tanks, melee groups
  with a shaman each, casters, healers).
- Each member shows their class and spec icon. The spec comes from their last sign-up or BiS list (dimmed) unless you
  pick one with right-click.
- The icons under each group are the buffs that group gets (Bloodlust / Heroism, Windfury, Battle Shout, Trueshot
  Aura, Leader of the Pack, Moonkin Aura, Vampiric Touch ...). The strip on top shows raid-wide buffs and boss debuffs;
  greyed icons mean nobody on the team brings it. Hover an icon to see who does.
- Click **Save** when you're done. Everyone else sees the team's groups read-only.

### A raid's groups and Invite & sort
- A raid's **Groups** tab (next to Sign-ups) starts from its team's groups: players who accepted keep their team seat,
  and other players who accepted fill the empty seats with the same role. Tentative and Bench wait under "Not in a
  group". Until you save, it follows new sign-ups.
- Adjust it like a team (drag, Auto-fill, **From team** to start over) and **Save**.
- As raid leader (or assistant), click **Invite & sort**: DisasterZone invites everyone placed in a group who is online,
  turns the party into a raid and moves each player into their group as they join. The status line shows who is in
  and who is offline. Players who join later are sorted automatically until you end the raid.
- **Re-sort** moves everyone in the raid back to their planned group, e.g. after swaps. Players who aren't in the plan
  go to groups 6-8. Nothing moves during combat; it continues when combat ends.

### Raid log and planned raids
- When the raid leader clicks **Start raid**, DisasterZone links the raid log to the planned raid automatically: the one you
  ran Invite & sort for, or the one most of the raid signed up for (it waits until that is clear, e.g. when two teams
  raid at the same time). The leader gets a chat line saying which raid it linked.
- At **End raid**, the sign-ups are saved with the raid log: players who signed up as Bench count as bench, and the
  council sees who accepted but didn't come ("no-show") in the Raid log, the Players view and the sign-up tooltips.
- Wrong link? Council: in the Raid log, right-click the "Planned raid" line and pick the right raid (or "Not linked").

---

## Members tab

Everyone has it. It shows what each member's DisasterZone shares with the guild; nothing needs to be filled in.

### Roster
- Every guild member with a dot for online (green), away (yellow) or offline (red), their level, main and off spec, and
  their professions with skill. Members who have not logged in with this version yet are listed in grey at the bottom.
- Click a member for the detail: their characters, each profession with its specialisation, and their recipes (click a
  profession to unfold them).
- The profession icons on top filter the list and show how many members have each profession.
- **Main and off spec** come from My BiS (the spec of your list and of your off-spec list). Without a pick there, your
  primary talents count as main spec and your secondary talents as off spec.

### Your recipes
- Your professions and skill are read by themselves.
- Recipes can only be read while the profession window is open: **open each of your profession windows once** (and again
  after learning new recipes). The tab reminds you which ones are missing. A filter in the window (for example "have
  materials") hides recipes from the scan; open it once without a filter.

### Recipes: who can craft what
- Switch to **Recipes** and type a name ("mongoose", "flask"). Each recipe lists its crafters, online first.
- **Whisper** opens a message to the crafter with the item or recipe linked. A crafter who is offline but playing
  another of their characters is shown as "on X now"; the whisper goes there.
- A recipe only one member knows is marked gold.
- Item tooltips everywhere say who in the guild can make the item.

### Alts
- Log in once on each of your characters in the guild. Then open your own entry in the roster and use **Change** to
  pick your main. Your alts then sit under your main for everyone.

### Officer notes (Guild Master and the rank below)
- A note of up to 600 letters per member, shown under the member's detail and in the roster tooltip. It is separate
  from the officer note of the game's guild window.
- Notes are sent only as whispers between officers, and an addon takes a note only from an officer. Members never
  receive them. They are stored in plain text on each officer's computer.

---

## Quick start: Loot Council

You are on the council if any of these apply:

- The Guild Master put you on the guild council.
- You are the Guild Master.
- You lead the raid you're in.
- The raid leader put you on this raid's council. This only counts while you are in that raid.

Settings → **Loot Council** tells you whether you are on the council, and why.

### Council tab

Toolbar controls:

- **Phase**
- View buttons: **Roster**, **Items**, **Member** and **Loot Council**
- **Drops**: opens the [boss drop panel](#drop-panel-boss-drop) with tonight's drops
- A name search box
- **All classes** and **All roles** dropdowns
- **In my raid only** and **Hide obtained** checkboxes (Hide obtained is on by default)
- **Off-spec lists**: the Roster, Items and Member views show the players' off-spec lists instead. Only players who have one are listed, with their off spec.

#### Roster

One row per member. Each row has:

- A presence dot: green = in your raid, yellow = online, grey = offline.
- The member's name, spec and **Need** count.
- 17 slot cells, one per slot.
- **Age**: how old their list is. It turns orange after 7 days.

What the slot cells show:

- A check mark means obtained. A star means awarded.
- A dark "–" means the player disabled that slot.
- A warning icon next to a name means the player changed their list while lists were locked.

Clicking:

- **Click a cell** to open the Items view at the boss that drops that item.
- **Right-click a cell**, or click the name, to open the Member view.
- **Click a column header** (Name, Need, Age) to sort.

#### Items

- The left side lists the phase's raids and bosses, with demand counts. 5-man, crafted and other non-raid items are under "Other / no raid source".
- The right side lists each item with its wanters. Main picks come first and alts are marked "(alt)".
- Click an item row for a menu: **Link item in chat**, **Announce to raid**, **Show member ▸** and **Record award to ▸**. The award submenu lists the wanters, plus **Someone else...**.
- While the item has a roll running or waiting for its award, the entry reads **Record award to (closes the open roll)**. The award then goes through the roll and closes it for everyone.

#### Member

One player's list as a read-only paper doll, with what they are wearing and their recent awards. The arrow buttons step through the filtered roster.

#### Footer

The footer shows how many members have lists, how many are in your raid, and how many lists are older than 7 days. **Request sync** asks online members for newer lists and awards.

### Drop panel (Boss drop)

The drop panel opens on its own when someone in the raid who runs DisasterZone loots a boss.

- It lists epic items by default. Tier tokens always count, whatever their quality.
- Loot from disenchanting, prospecting, lockboxes and other containers, and from fishing, is ignored. So are trade goods and gems that no boss drops (such as Void Crystals). Trash loot is never filed under the last boss killed.
- When Blizzard's loot window is open, the panel sits beside it: on the right, or on the left when there is no room (for example with Loot Under Mouse near the screen edge). Otherwise it floats where you last dragged it. See Settings → **Drop panel position**.
- Reopen it with the **Drops** button in the Council toolbar, by Shift-clicking the minimap button, or with `/dz drops`. The arrows page through the last 24 hours of drops.
- While the panel shows an item that is still being decided (a roll is running, or closed less than 5 minutes ago and waiting for its award), a new drop doesn't replace it. The pager then turns orange and reads, for example, "3/4 new". Page forward to see the new drop.

Each item shows how many want it ("3 want") and its candidates. A candidate row contains:

- A presence dot and the player's name and spec.
- **[BiS]** or **[Alt]**, plus the phase when it isn't the one you're viewing.
- "can't use" (in red) when their class can't use the item. This covers class-restricted items (T5 class trinkets, Warglaives, PvP set pieces, Ashtongue talismans) and other classes' tokens.
- "won N" when they already won items tonight. Offspec, disenchant and guild bank awards don't count.
- The items they wear in that slot.
- "not in raid" when they aren't in your raid.
- A warning icon when their list changed while lists were locked.

Buttons for each item:

- **Announce** posts one line to raid chat, for example `DisasterZone: [item] - BiS: A, B; Alt: C`.
- **Award...** opens a menu with:
  - **Disenchant: Name** and **Guild bank: Name**, when those characters are set (see [Disenchanter and guild bank](#disenchanter-and-guild-bank));
  - the candidates who are in the raid, marked "can't use" when it applies. A main pick is recorded as **BiS**, an alt pick as **Alt**;
  - **Other raid member ▸**;
  - **Award as offspec ▸**: the same players, recorded as **Offspec**;
  - **Not in raid (n) ▸**: wanters who aren't in the raid, each marked "online" or "offline";
  - **Someone else...** (the dialog has a **Reason** choice);
  - once the item is awarded: **Reason: X ▸** to change the award's reason, and **Void the award to X**.

  It records the award in the Loot Log. It doesn't trade the item or give it via master loot, so hand the item out yourself.
- **Roll** starts a roll for this item. See [How rolls pick a suggested winner](#how-rolls-pick-a-suggested-winner).
- **DE** and **Bank** give the item to the disenchanter or the guild bank character in one click. They are shown while nobody has been picked for the item, and only when that character is set. As master looter with the loot window open, DisasterZone asks "Give [item] to Name (Disenchant)?" and hands it over. Otherwise the award is only recorded.

Footer buttons: **Announce all**, **Roll all**, **Lock lists** / **Unlock lists** (shown only to the raid's loot leader) and **Close**.

Once an item has a roll, its block switches to roll mode:

- The header shows "Rolling - 0:18 left", "Queued", "Rolls closed" or "Awarded to X".
- Each row shows the player's roll. The suggested winner is highlighted. Other tags: "tie", "can't use", "won a copy", "won N" and "changed".
- **Votes:** every council member in the raid has one vote per item. Click the vote column of a row (it reads "vote") to vote for that player. The column then shows a check mark and the number of votes, in gold when your vote is among them. Click again to take your vote back, or vote for someone else to move it. Hover a row to see who voted. Votes can change until the item is awarded. See [How rolls pick a suggested winner](#how-rolls-pick-a-suggested-winner).
- While the roll is open: **End roll**, and **End roll & award to** *suggested player*. The second one ends the roll for everyone at once, and cancelling the next popup doesn't reopen it.
- After the roll has closed: **Award to** *suggested player*, **Award...** (for anyone else) and **Re-roll**. If anyone rolled, Re-roll asks first: "Start a new roll for [item]? (N rolls so far are discarded)".
- When nobody is suggested (nobody rolled and nobody voted), **DE** and **Bank** are shown as well.
- **Cancel roll** removes a queued item from the queue.
- Click or right-click a row for **Vote for Name** / **Remove my vote**, **Award to Name** (**End roll & award to Name** while the roll is open), **Award to Name as ▸** a reason, or **Link item**.
- An award from a roll is recorded with the winner's BiS status as its reason (**BiS**, **Alt**, or **Upgrade** when the item isn't on their list), unless you picked a reason with **Award to Name as ▸**.
- A long list ends in a "+N more" row. Click it to award one of the hidden players.

If you award an item that has a roll, the roll closes for everyone and the popups fade.

**When the loot message disagrees.** Sometimes the loot message for a rolled item names someone other than the recorded winner, and no other copy of the item explains it. DisasterZone then warns the council and the master looter in chat, and the item's line reads "Awarded to X · loot: Y". Council members can fix the log in one click from that item's **Award...** menu:

- **Y passes it to X** keeps the award and voids Y's automatic log entry.
- **Y keeps it (void the award to X)** voids the award to X and shows Y as the winner.

### Loot Log tab

- **Automatic entries:** when your client sees "X receives loot: [item]" inside a raid instance (or a 5-man dungeon in dungeon mode), DisasterZone records it. This covers boss loot at or above the minimum quality, plus tier tokens.
- **Manual entries:** awards from the drop panel, or **Add award...**. The dialog has an **Item** field (shift-click a link, drag an item, or type the item ID), a **Winner** field (type a name or use **Choose**), a **Note**, a **Reason**, and **Save**.
- **Reason column:** why the item was given. Automatic entries have none until someone sets one.

  | Reason | Counts as loot received ("won N") | Marks the item as awarded on the winner's list |
  |---|---|---|
  | **BiS** | yes | yes |
  | **Alt** | yes | yes |
  | **Upgrade** (not on their list) | yes | yes |
  | **Offspec** | no | yes |
  | **Disenchant** | no | no |
  | **Guild bank** | no | no |

  Reasons that don't count are shown in grey.
- **Duplicates:** when a manual award and the later loot message are for the same item and player, only the manual entry is shown.
- **Filters:** a search box (player, item or reason), **Show voided**, and **Show dungeon loot** (dungeon entries are tagged "(dungeon)").
- **Right-click an entry** for **Reason: X ▸**, **Void entry** / **Restore entry**, **Link item in chat** and **Show member**. Changing the reason, voiding or restoring an automatic entry also covers the copies of that loot line that other council members recorded.
- The log is shared automatically between council members.

### Tooltips (council)

Item tooltips add "DisasterZone: wanted by N (M in raid)" and a list of names. When some of the picks are alts, " · K BiS" follows with the number of main picks.

- Each name is marked "(alt)" for an alt pick, or with the phase when it isn't the one you're viewing. The right side shows "in raid", "obtained", "awarded" or "can't use".
- Hold **Shift** to see every name, plus "Wearing:" lines with what each player still needing the item has equipped in that slot. The "Wearing:" lines only appear while Shift is held.
- Settings → **Names shown** sets how many names appear.

---

## Quick start: Raid leader

While you lead a raid you are on the council for that raid, so you see the Council tab.

### Group loot rules

Set these in Settings → **Group loot rules**. They are sent to everyone in the group:

| Setting | Values |
|---|---|
| **Roll duration** | 15 / 20 / 30 / 45 / 60 seconds (default 30) |
| **Minimum quality** | Epic (default) / Rare: the lowest quality that counts as a drop in raids. Tier tokens always count. |
| **Raid phase** | "Use guild phase (Pn)" or P1–P5. Council views, tooltips, alerts and roll suggestions in your raid follow it. |
| **Enable dungeon mode (5-man parties)** / **Dungeon min. quality** | See [Dungeon mode](#dungeon-mode-5-man-parties) |

- The status line reads "You set these for your group".
- Everyone else sees "Set by *your name* for this group", and their controls are greyed out.
- `/dz rules` prints the rules in effect and who set them.

**Who is the group's loot leader:**

- In a raid, the raid leader. If the leader doesn't run DisasterZone, the master looter.
- In a party, the party leader if they are on the council or turned dungeon mode on. Otherwise, a council member in the party.

Without a loot leader who runs DisasterZone, everyone uses their own settings.

### Raid council

Pick extra council members for your raid:

1. Open Council tab → **Loot Council** → **This raid's council**.
2. Type in **Add raid or guild members...**. Raid members are listed first. Click a name, or press Enter, to add or remove them.
3. Click **Save & share**. **Revert** discards unsaved changes, and **Clear list** empties the list after asking.

How the raid council works:

- These players count as council only inside your raid, and only for people in that raid.
- The list is kept "until changed". It is sent again automatically whenever you lead a raid.
- You stay council yourself as raid leader.
- The same section has **Disenchanter** and **Guild bank** buttons. A pick there replaces the Guild Master's pick in the raids you lead, for example when the guild's disenchanter isn't in this raid. Leave them on "none" to use the guild's picks. See [Disenchanter and guild bank](#disenchanter-and-guild-bank).

### Lock and unlock BiS lists

Lock the lists with `/dz lock` and unlock them with `/dz unlock`. The **Lock BiS lists** / **Unlock BiS lists** button in Settings or the Council toolbar does the same, as does **Lock lists** in the drop panel footer.

- Only the raid's loot leader can lock, and only in a raid.
- When you lock, raid chat gets "DisasterZone: BiS lists are locked for this raid." once. This happens only if **Announce rolls and winners in raid chat** is on.
- Nobody can change picks, spec or disabled slots. That includes you: unlock to edit.
- Obtained items still update.
- **Changed during lock:** if a player's list changes anyway, council members see a warning icon next to that player and one chat warning. That player is never the suggested roll winner, but the council can still award to them.
- Sometimes a changed list claims it was saved before the lock, although DisasterZone can tell it wasn't. That list isn't flagged. Council members get a chat note instead ("...claims an earlier save ...; not flagged, please check."), and the player can still be suggested.
- The lock ends on unlock, when the raid disbands, when the lead changes, or when the raid turns into a party. It survives your own `/reload`.

### Rolls and master-loot give

Who can start rolls: council members, the master looter, and the raid leader or assistants. Start them with **Roll** or **Roll all** in the drop panel, or with `/dz roll [item link]`.

To have DisasterZone hand items out:

1. Set the loot method to Master Looter.
2. As master looter, keep the boss loot window open.
3. In the drop panel's roll mode, click **Award to** *name* (**End roll & award to** *name* while the roll is open), or click a roll row → **Award to Name**.
4. A popup asks "Give [item] to Name?". Click **Give**. DisasterZone gives the item via master loot.
5. The award is recorded and announced only once the server has handed the item over.

If the item can't be given, DisasterZone prints "Could not hand [item] to Name: *reason*". This happens when the server refuses (full bags, a unique item, out of range), doesn't answer within 5 seconds, or the loot window is closed. Nothing is recorded or announced yet. DisasterZone then offers to award it anyway: "Award [item] to Name? (hand it out via master loot or trade)". **Award** only records and announces the award.

The plain **Award...** menu never hands the item out. It only records.

### Dungeon mode (5-man parties)

Dungeon mode shares boss drops and DisasterZone rolls in a 5-man party the same way it works in a raid.

- **Turn it on:** type `/dz dungeon on`, or tick **Enable dungeon mode (5-man parties)**.
  - As party leader, you turn it on for the whole party.
  - If the party leader isn't on the council and hasn't turned it on, a council member in the party can turn it on for everyone.
  - A regular party member turning it on only affects their own client, and only when the party has no loot leader.
- **Minimum quality:** Rare by default. Change it with `/dz dungeon epic` or `/dz dungeon rare`.
- **What it does:** drops inside 5-man dungeons are shared with the party, rolls run in party chat, and the party leader and council get the drop panel. Awards are tagged "(dungeon)" in the Loot Log and don't count towards "won N tonight".
- **Turn it off** with `/dz dungeon off`. `/dz dungeon status` shows the current state.
- Dungeon mode only works in a party. Raids always work as normal.

---

## Quick start: Guild Master

The Guild Master is always on the council.

### Pick the guild council

1. Open Council tab → **Loot Council** → **Guild council**. You can also get there from Settings → **Loot Council** → **Edit council…**.
2. Type in **Add guild members...**.
   - The list shows online guild members. Tick **Show offline members** to see everyone.
   - Click a name, or press Enter, to add or remove it. Arrow keys move the selection and Escape closes the list.
3. Set **Guild phase** (P1 · Karazhan · Gruul · Magtheridon, … P5 · Sunwell Plateau).
4. Optional: pick the **Disenchanter** and the **Guild bank** character (see below).
5. Click **Save & share**. The status reads "Shared 2m ago · N members · phase Pn".

How it works:

- A list holds up to 40 names.
- **Revert** discards unsaved changes. **Clear list** removes everyone after asking. You stay council.
- The list reaches online members at once. Members who log in later get it within about a minute, either from you or from a council member.
- To remove someone, take them off the list and click **Save & share** again. They lose council status everywhere: the Council and Loot Log tabs close, and they stop receiving lists.
- Your own client only trusts the list you saved yourself, and that list is stored on the PC you saved it on. If you play the GM on another PC, DisasterZone may print "Your guild council list is not saved on this PC: open Council > Loot Council and save it again". Save it once on that PC.

### Disenchanter and guild bank

The drop panel's **DE** and **Bank** buttons give an item to these characters in one click. Such awards are recorded as **Disenchant** or **Guild bank**, so they don't count as loot received and don't mark the item as awarded on that character's own BiS list.

- Set them in Council tab → **Loot Council** → **Guild council**, with the **Disenchanter** and **Guild bank** buttons. Each button lists raid members, online guild members and all guild members, plus **None**.
- **Save & share** sends them to the guild together with the council list.
- A raid leader can pick different characters for their own raid (see [Raid council](#raid-council)). Their pick wins inside that raid.
- Everyone else sees both names as a line in the Loot Council view.
- If the character isn't in the raid, the button is greyed out.

### Phases

| Phase | Set by | Applies to |
|---|---|---|
| Guild phase | the GM, in the picker | everyone: the default My BiS phase, council views, tooltips and alerts |
| Raid phase | the raid leader, in Group loot rules | that raid only |
| View phase | each player, in Settings | only that player's own views |

DisasterZone no longer uses the Guild Information text. If an old `CDL{...}` line is still there, you can delete it.

---

## How rolls pick a suggested winner

**Council votes come first.** As soon as any council member has voted on an item, the player with the most votes is suggested:

- Only votes for players who are still in the raid and didn't pass count.
- Equal votes are decided by the groups below (BiS main, then BiS alt, then off-spec list, then everyone else), then by a valid roll (a player who rolled beats one who didn't), then by the higher roll. If that still doesn't separate them, the rows are marked "tie".
- The council chose deliberately, so a voted player can be suggested even when they are marked "changed", "can't use" or "won a copy".
- Only council members' votes count. A vote from someone who has since left the council is ignored.

**Without votes**, DisasterZone sorts everyone who rolled into four groups:

1. **BiS main**, not obtained yet
2. **BiS alt**, not obtained yet
3. **Off-spec list** (main or alt pick), not obtained yet
4. **Everyone else**: not on their list, already obtained, the slot is disabled, their class can't use the item ("can't use"), or they already won another copy of it from this drop ("won a copy")

The highest roll in the best group is **suggested**. Some rules apply:

- The groups follow the raid's phase: the **Raid phase** from Group loot rules, otherwise the guild phase. A council member's own **View phase** doesn't change them, so every council member sees the same suggestion.
- A master looter who isn't on the council, even one from another guild, gets the same ranking from the council members in the raid.
- A roll outside 1-100 is shown but never suggested.
- A second roll is ignored and shown as "×2".
- A roll that arrives more than 2 seconds after the timer ends doesn't count.
- These players are never suggested, even if they are the only ones who rolled (they stay listed, and the council can still award them by clicking the row):
  - anyone flagged "changed during lock";
  - anyone marked "can't use";
  - anyone marked "won a copy";
  - anyone who has left the group.

  If only such players rolled, there is no suggestion.
- When rolls tie, every tied row is marked "tie". Pick a winner by clicking their row, or click **Re-roll**.
- "won N" (items won tonight) is shown for your information only. It doesn't change the suggestion.

The council always confirms the award. Nothing is given away without a click and a confirmation popup.

---

## Slash commands

`/dz` and `/disasterzone` work the same way.

| Command | What it does | Who |
|---|---|---|
| `/dz members` | Open the Members tab: professions, recipes, specs, alts | Everyone |
| `/dz professions` | How many characters and recipes the guild shares, and which of your windows to open | Everyone |
| `/dz` | Opens or closes the window | everyone |
| `/dz help` (or `/dz ?`) | Lists all commands | everyone |
| `/dz home` | Opens the Home tab | everyone |
| `/dz bis` | Opens the My BiS tab | everyone |
| `/dz changelog` | Opens the Changelog tab | everyone |
| `/dz council` | Opens the Council tab (My BiS if you aren't council) | council |
| `/dz log` | Opens the Loot Log tab | council |
| `/dz raids` | Opens the Raids tab: upcoming raids and sign-ups | everyone |
| `/dz plan` | Lists the planned raids and your answers in chat | everyone |
| `/dz settings` or `/dz config` | Opens Settings | everyone |
| `/dz sync` | Asks the guild and council to sync lists now (at most once per 30 s) | everyone |
| `/dz version` | Your version and the versions seen in the guild | everyone |
| `/dz demo [on\|off]` | Turns demo mode on or off, or toggles it | everyone |
| `/dz test` | Simulates a boss drop on your own screen only. Nothing is sent. | everyone |
| `/dz drops` | Shows the drop panel with the last 24 h of drops | mainly council / ML |
| `/dz drop <item links>` | Announces a drop to the raid by hand (shift-click the items into the command) | council, raid leader / assistants |
| `/dz roll <item link>` | Starts a roll for an item. Several links are queued. An item ID also works. | council, master looter, raid leader / assistants |
| `/dz roll end` | Ends the running roll | the starter or council |
| `/dz rules` | Shows the group loot rules in effect and who set them | everyone |
| `/dz lock` / `/dz unlock` | Locks or unlocks every BiS list in the raid | raid loot leader |
| `/dz dungeon [on\|off\|rare\|epic\|status]` | Dungeon mode for 5-man parties (no argument toggles it) | everyone (party leader / council for the whole party) |
| `/dz debug` | Turns debug messages in chat on or off | only when asked to |

---

## Settings reference

All settings are in the **Settings** tab. The ones marked *group rule* come from your group's loot leader while you are in a group.

| Section | Setting | Default |
|---|---|---|
| Alerts | Boss drop panel (Loot Council) | on |
| | "On your BiS list!" toast | on |
| | Play a sound with drop alerts | on |
| | Glow loot buttons for your BiS items | on |
| | Chat message when your BiS item drops | on |
| | BiS badges on the loot window | on |
| | Alerts for off-spec list items (toast and chat line) | on |
| | Drop panel position: Attach to loot window when open / Always floating | Attach |
| | Announce channel: Raid / Raid Warning (Raid Warning needs lead or assist; otherwise Raid is used) | Raid |
| Group loot rules | Roll duration *(group rule)* | 30 seconds |
| | Minimum quality *(group rule)* | Epic |
| | Enable dungeon mode (5-man parties) *(group rule)* | off |
| | Dungeon min. quality *(group rule)* | Rare |
| | Raid phase *(group rule)* | Use guild phase |
| | Lock BiS lists / Unlock BiS lists | — |
| Rolls | Announce rolls and winners in raid chat | on |
| | Show the Roll / Pass popup | on |
| Tooltips | Show DisasterZone lines on item tooltips | on |
| | Council: list who wants the item | on |
| | Names shown: 3 / 5 / 8 / 12 | 5 |
| Minimap button | Show the minimap button | on |
| View phase | Phase: Follow guild (Pn) / P1–P5 | Follow guild |
| Demo mode | Demo data (fake guild members & raid), plus the **Simulate a boss drop**, **Recent drops** and **Demo a roll** buttons | off |
| About | Version, peers seen, sharing status, **Request sync**, Debug messages in chat | — |
| Loot Council | Read-only summary of the guild council and this raid's council, plus **Edit council…** for the GM or raid leader | — |

---

## Demo mode (try it solo)

Turn demo mode on with `/dz demo`, or tick **Demo data (fake guild members & raid)** in Settings.

What it adds:

- Fake guild members with BiS lists, some of them in a pretend raid.
- The Council and Loot Log tabs, even if you aren't council.
- Your own My BiS list stays real.

Things to try:

- **Simulate a boss drop** (or `/dz test`) opens the drop panel, plus your own toast if a dropped item is on your list.
- **Demo a roll** starts a roll on a simulated drop. You get the Roll / Pass popup, and fake raiders roll in the drop panel.
- You can also click **Roll** on any item in the drop panel.

Demo data is never saved or sent:

- Announces print only in your own chat, as "[demo, not sent] ...".
- Awards go into a temporary log that is thrown away when demo mode is turned off.

`/dz demo` again turns it off.

`/dz test` also works without demo mode. It uses real guild lists but still sends nothing. Rolls on a simulated drop need demo mode.

---

## FAQ and troubleshooting

### What does the sync status mean?

The status appears at the top-right of the window, on the My BiS card under **Sharing**, and in the minimap tooltip.

| Status | Meaning | What to do |
|---|---|---|
| **Shared with council ✓ 5m ago** | A council member has your current list. | Nothing |
| **Changes pending…** | You edited your list recently. It is sent about 8 s after the last edit, or when you close the window. | Wait, or close the window |
| **Sharing with council…** | A council member is online but hasn't confirmed your current version yet. | Wait a minute |
| **Not shared yet — no council member online** | Nobody who may receive lists is online. Your list is sent automatically when a council member logs in. | Nothing, or `/dz sync` later |
| **Waiting for guild roster…** | The guild roster hasn't loaded yet. | Wait a moment, or open the guild window |
| **Not in a guild** | Sharing is off. My BiS, tooltips and your own alerts still work. | — |

A list with no picks at all is never sent. Choose at least one item.

### "Not shared yet" won't go away
- Check that someone on the council is actually online. `/dz version` lists players who have DisasterZone and marks council members.
- Type `/dz sync`, wait 30 seconds, and look again.
- If a council member is online and nothing changes, check that you both run the same version.

### The Council tab is missing
Only council members see it. Ask the Guild Master to add you, or check Settings → **Loot Council**. To look around anyway, use [demo mode](#demo-mode-try-it-solo).

### As council, I don't see someone's list
- Lists arrive when that player is online at the same time as a council member. Click **Request sync** in the Council footer.
- Lists of players who left the guild are removed after 30 days.

### The drop panel didn't open
The drop panel needs all of these:

- You are on the council, or you lead a party in dungeon mode.
- **Boss drop panel (Loot Council)** is on.
- Someone in the raid who runs DisasterZone opened the boss loot window. Under master loot, that must be the master looter, the raid leader, an assistant or a council member; other raiders' loot windows are ignored.
- An item met the minimum quality (Epic by default). Tokens always count.
- It was a real drop. Disenchanting, prospecting, lockboxes and fishing never open it.
- The panel wasn't already busy. If it shows an item that is still being decided, it stays on that item and the pager reads "new". Page forward.

If it still didn't open:

- Reopen the panel with the **Drops** button in the Council toolbar, Shift-click on the minimap button, or `/dz drops`.
- Announce a drop by hand with `/dz drop [item] [item]`.

### My roll wasn't counted
- Only `/roll` 1-100 counts, and only your first roll counts.
- The roll must land before the timer ends, or up to 2 seconds after.
- Rolls typed while no DisasterZone roll is open are ignored.

### A council member has a newer copy of my list
DisasterZone shows the popup "A council member (X) has a newer copy of your BiS list… Restore it?".

- **Restore** takes their copy. Use it after reinstalling, or after losing your SavedVariables.
- **Keep mine** keeps your local list and sends it out as the newest version.
- Escape only closes the popup. Nothing is restored or sent.

A fresh install with an empty list is restored automatically.

### "X doesn't fit the Head slot" / "is a token / quest item"
- Pick an item that fits the slot you clicked.
- For tier sets, pick the tier piece, not the token. The picker lists the pieces under the boss.

### Mixed versions
- Everyone, and above all council members, the raid leader and the master looter, should run the **same** version. `/dz version` shows who runs what.
- If a newer version shows up, DisasterZone prints "A newer DisasterZone version (x) is in use by Y. Please update."
- **Off-spec lists** need 0.6 on the council's side: 0.5 council members keep receiving your list but ignore the off-spec part.
- **0.5 and older** don't know votes, award reasons or the disenchanter / guild bank:
  - A 0.5 council member can't vote and doesn't see votes. Its awards have no reason.
  - A master looter on 0.5 gets no suggestion from votes.
  - A client that first gets the council list from a 0.5 member may miss the disenchanter / guild bank until the Guild Master saves the list again.
- **0.4 and older** still send disenchant and lockbox loot as drops (0.5 ignores them). A master looter on 0.4 also records a master-loot give before the server has handed the item over. Update the master looter first.
- **0.3 and older** ignore disabled slots and the raid lock. A 0.3 council member still counts a disabled slot as wanted.
- **0.2 and older** use the old Guild Information council and don't know the picked council. Their lists may not reach the new council.
- If DisasterZone prints "X uses an incompatible DisasterZone version (protocol …)", messages between you and X are dropped until one of you updates.

### Something looks stuck
- `/reload` rebuilds the windows.
- Rolls in progress are kept in memory only. Avoid `/reload` on the client that started a roll until the roll is awarded.
- If DisasterZone fails mid-raid, hand the item out the normal way (master loot or trade). Record it afterwards with Loot Log → **Add award...**.

### Reporting a Lua error
1. Install **BugSack** from CurseForge. It needs **!BugGrabber**; the CurseForge app installs both.
   Without BugSack, type `/console scriptErrors 1` to get the game's own error window.
2. When an error happens, open BugSack from its minimap icon or with `/bugsack`. Copy the **whole** error text, including the stack lines under it.
3. Send it to whoever maintains DisasterZone for the guild, together with:
   - your version (the first line of `/dz version`);
   - what you were doing (for example "clicked Award to X in the drop panel");
   - whether you were solo, in a party or in a raid, and your role there (raider, council, raid leader, master looter);
   - whether demo mode was on.
4. Only turn on `/dz debug` if you are asked to. It prints extra messages to chat.

---

## How it syncs, and privacy

- **Your BiS list goes only to the council, by whisper.**
  - It includes your picks, disabled slots, class, spec, which listed items you own, and what you wear in each slot.
  - It goes to online guild council members and the GM. The raid leader and raid council members get it only while you are in their raid.
  - Guild council members pass lists on to each other by whisper. Raid-only council members never pass lists on.
  - Regular raiders never receive other players' lists.
- **The guild channel carries only small status messages:**
  - your list's revision number and your addon version;
  - from council members: which lists they hold (names, revision numbers and checksums) and a checksum of the award log per day;
  - the guild council list (names, phase, disenchanter and guild bank character) from the GM.
  So the guild can see who has a list and how often it changes, but not what is on it.
- **The raid or party channel carries loot events:** drops (item IDs), roll starts, rolls and results, council votes (who voted for whom), group loot rules, the raid council names with the raid's disenchanter / guild bank pick, and the lock. The raid UI only shows votes to council members and the master looter, but a modified client in the raid could read them.
- **The loot log is council only.** It is shared between council members by whisper. Full history is exchanged only between guild council members. Raid-only council members receive the awards made while they are in the raid. They can only add awards they record themselves, and only void or restore awards from the last 12 hours.
- **Where it's stored:** everything stays inside the game. Council members keep copies of other players' lists in their own SavedVariables file.
- **It is not cryptographic.**
  - The checksums catch damaged or out-of-date data, not forgery.
  - Who sent a message comes from the game's addon channel, and council status comes from the live guild and raid rosters.
  - DisasterZone refuses the known ways a modified client could interfere with others: overwriting lists, injecting or voiding awards, taking over the guild council list, cancelling running rolls, overriding awards, claiming boss drops, or freezing clients with oversized messages.
  - A player with a modified client can still send whatever they like about their own list. The "changed during lock" warning is a detection aid, not a guarantee.
  - Treat DisasterZone as a helper for an honest guild, not as a security system.

---

Third-party libraries and data sources: see [NOTICE.md](NOTICE.md).
