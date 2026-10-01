-- CDLoot: the last file in the TOC. Lets the boot loader run the files an in-game update added after
-- everything else (Core/Boot.lua). Never part of an in-game update.
if CDLootBoot and CDLootBoot.End then CDLootBoot.End(...) end
