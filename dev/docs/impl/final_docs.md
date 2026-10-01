I wrote `README.md` and `NOTICE.md`; three findings contradict the brief and are recorded in `NOTICE.md`.

1. **`README.md`** covers install/update, quick starts for raider, council, raid leader and GM, and how the roll suggestion works. It also has all 18 slash commands with who may use each, a settings reference, demo mode, FAQ/troubleshooting and the sync & privacy section. Every command, button label, menu entry and status string was checked against the Core/UI code.
2. **Loon claim:** "no LoonBestInSlot data is shipped" is true for files and BiS/guide data, but 10 item IDs in `Data\Items.lua` name LoonBestInSlot as a supplement source. They are one Magtheridon's Head variant and nine "of the Forgotten" tokens under Eredar Twins, which the data already marks unconfirmed. Another 17 IDs name LootReserve.
3. **Other data sources:** the generators also took numbers from Deadly Boss Mods (creature and encounter IDs; its installed licence says "All Rights Reserved") and from Questie's databases (Questie has no licence file installed).
4. **Library licences:** ChatThrottleLib is public domain, not Ace3 BSD. LibDataBroker-1.1 has no written licence anywhere I could find; its CurseForge page shows "All Rights Reserved". LibDBIcon (Ace3 Style BSD) and CallbackHandler (BSD) carry their licence only on CurseForge, not in the files.
5. **GPL:** AtlasLootClassic is GPL v2, confirmed from its `LICENSE` file and the `X-License` line in every module. `NOTICE.md` warns that redistribution may bring GPL terms, and notes that DisasterZone ships no copy of the GPL text.

Files are in C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone:
- README.md
- NOTICE.md