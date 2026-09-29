-- CDLoot: Data/Changelog.lua
-- The release notes shown in the Changelog tab, newest release first.
-- To add a release: put a new table at the top with the version it ships as. A version newer than the installed
-- one is shown as "In testing" until the TOC version catches up. Sections group the changes; one short line per
-- change, in plain words, saying what players notice.
local addonName, ns = ...

ns.CHANGELOG = {
    { version = "0.7.0", date = "29 September 2026", title = "Raid planning, Home and Games",
      sections = {
          { heading = "Home", lines = {
              "CDLoot now opens on Home: only what needs you right now.",
              "To-do chips for raids to answer, empty BiS slots and updates.",
              "Next raid with one-click Accept, Tentative, Bench and Absent.",
              "Several raids on one day? Pick one from the pills on the card.",
              "Your BiS picks that can drop in that raid, and which boss drops them.",
              "The BiS card follows the raid's phase; arrows show other phases.",
              "Recent loot, and a readiness check for the council and raid leaders.",
              "Settings > Main window > Open on: Home or the tab you used last.",
          } },
          { heading = "Raid sign-ups", lines = {
              "The Raids tab lists upcoming raids; everyone can sign up.",
              "Answer Accept, Tentative, Bench or Absent, with your spec and a note.",
              "Weekly raids repeat on their own; a reminder at login lists unanswered raids.",
              "Hover a name to see when they signed up.",
          } },
          { heading = "Planning (Guild Master, raid leaders, council)", lines = {
              "Officers pick the raid leaders; the Guild Master and raid leaders plan raids.",
              "Teams with specs and a group layout; the Guild Master and council build them.",
              "Drag players between groups, swap whole groups, or press Auto-fill.",
              "Party buff icons on every group.",
              "Invite & sort invites the raid and moves everyone into their group.",
              "A calendar picks the raid date. Raids can be deleted.",
              "The raid log links each raid to the planned one: bench, no-shows and reliability.",
          } },
          { heading = "Also new", lines = {
              "Games tab: Council Bingo and Azeromon (it has its own What's new).",
              "This Changelog tab.",
              "New commands: /cdl home, /cdl bis and /cdl changelog.",
          } },
          { heading = "Fixed", lines = {
              "A raid-only council member sees just that raid's lists and awards.",
              "Votes, attendance and raid log items only show to those allowed.",
          } },
      } },
    { version = "0.6.0", date = "28 September 2026", title = "Votes, off-spec lists and the raid log",
      sections = {
          { heading = "Award reasons", lines = {
              "Every award has a reason: BiS, Alt, Upgrade, Offspec, Disenchant or Guild bank.",
              "Offspec, disenchant and guild bank awards don't count as loot won.",
              "Change a reason later in the Loot Log; the change syncs to the council.",
          } },
          { heading = "Council votes", lines = {
              "The council votes on every roll; each member has one vote.",
              "The most-voted player is suggested; voter names are shown.",
          } },
          { heading = "Disenchanter and guild bank", lines = {
              "The Guild Master names a disenchanter and a guild bank character.",
              "The raid leader can pick others for their raid.",
              "One-click DE and Bank buttons in the drop panel.",
          } },
          { heading = "Off-spec lists", lines = {
              "Keep one off-spec BiS list next to your main one (My BiS header).",
              "Off-spec wanters rank after main-spec alts in rolls.",
              "Off-spec wins are logged as Offspec.",
          } },
          { heading = "Raid log", lines = {
              "The raid leader clicks Start raid and End raid.",
              "Starting a raid also locks the BiS lists; a bar shows the raid is on.",
              "Bosses, attendance and loot of every raid, in the Raids tab.",
              "Attendance shows in the council views.",
          } },
      } },
    { version = "0.5.0", date = "28 September 2026", title = "Safer loot decisions",
      sections = {
          { heading = "Loot decisions", lines = {
              "Disenchanting, lockboxes and fishing no longer show up as boss drops.",
              "A master-loot give counts only once the item is really handed over.",
              "Players who can't use an item or token are never suggested.",
              "Roll suggestions use the raid's phase.",
              "The winner of a first copy isn't suggested for the second.",
              "A loot message naming someone else offers a one-click fix to the log.",
          } },
          { heading = "Protection", lines = {
              "Modified clients can no longer overwrite lists, fake awards or take over the council.",
              "Oversized messages can no longer freeze your game.",
          } },
          { heading = "Interface", lines = {
              "The drop panel attaches to the loot window and no longer jumps around.",
              "A drop still being decided stays on screen when a new one arrives.",
              "New Drops button in the Council tab; Shift-click the minimap icon to reopen drops.",
              "Clearer buttons and counts; long names are no longer cut off.",
          } },
          { heading = "Fixed", lines = {
              "The award log no longer stays empty after a fresh login.",
              "Escape on the \"newer copy\" popup no longer overwrites the council's copy.",
              "Less network traffic after a boss kill.",
              "Corrected phases for a few items.",
          } },
      } },
    { version = "0.4.0", date = "28 September 2026", title = "More item sources and the raid lock",
      sections = {
          { heading = "Item picker", lines = {
              "New Sources menu: raids, 5-man dungeons, crafted, reputation, badges and PvP.",
              "Raids and 5-man dungeons are the default; your choice is remembered.",
              "Crafted, reputation, badge and PvP gear shows its profession, standing or cost.",
          } },
          { heading = "My BiS", lines = {
              "Right-click a slot to disable it for one phase or for all phases.",
              "Disabled slots are left out of progress, council counts and alerts.",
          } },
          { heading = "Raid lock", lines = {
              "The raid leader can lock every BiS list for the raid (/cdl lock).",
              "The council sees a warning on anyone whose list changes anyway.",
          } },
      } },
    { version = "0.3.0", date = "28 September 2026", title = "Council picker, group rules and dungeons",
      sections = {
          { heading = "Loot council", lines = {
              "The Guild Master picks the guild council from a list of guild members.",
              "Raid leaders can add council members for their own raid.",
              "CDLoot no longer uses the Guild Information text.",
          } },
          { heading = "Group loot rules", lines = {
              "The raid leader sets roll time, minimum quality, phase and dungeon mode for everyone.",
              "Everyone else's Settings show who set them (/cdl rules).",
          } },
          { heading = "Dungeon mode", lines = {
              "Loot sharing and rolls for 5-man parties (/cdl dungeon).",
              "5-man loot in the item picker, with a Heroic tag.",
              "Dungeon awards are tagged and don't count as won tonight.",
          } },
          { heading = "Rolls", lines = {
              "Roll popups close a few seconds after the item is handed out.",
              "Award... and Someone else... close the roll and log one entry.",
          } },
      } },
    { version = "0.2.0", date = "28 September 2026", title = "Rolls",
      sections = {
          { heading = "Rolls", lines = {
              "Everyone in the raid can Roll or Pass on a drop.",
              "CDLoot suggests the winner: BiS main first, then BiS alt, then everyone else.",
              "The council confirms; the master looter can hand the item out from CDLoot.",
          } },
          { heading = "Council", lines = {
              "Rings, trinkets and weapons show both items a player wears.",
              "Changing the phase jumps to that phase's first boss.",
          } },
          { heading = "Fixed", lines = {
              "Picking a tier token picks your class's tier piece.",
              "Sharing works right after a /reload; lists edited on two PCs are repaired.",
              "The award log is kept per guild.",
              "Demo mode never posts fake names to raid chat.",
          } },
      } },
    { version = "0.1.0", date = "27 September 2026", title = "First release",
      sections = {
          { heading = "Everyone", lines = {
              "Build your BiS list per phase: a main pick and an alt for every slot.",
              "Items you own are ticked off automatically.",
              "Your list is shared with the loot council.",
              "An \"On your BiS!\" alert when one of your items drops.",
              "CDLoot lines on item tooltips.",
          } },
          { heading = "Loot council", lines = {
              "The Council tab shows everyone's lists, by player, item and boss.",
              "A drop panel on every boss shows who has each item on their list.",
              "The Loot Log keeps every award.",
              "Demo mode to try it all out alone.",
          } },
      } },
}
