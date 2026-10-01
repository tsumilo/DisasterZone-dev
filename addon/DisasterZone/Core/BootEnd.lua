-- DisasterZone: the last file in the TOC. Lets the boot loader run the files an in-game update added after
-- everything else (Core/Boot.lua). Never part of an in-game update.
if DisasterZoneBoot and DisasterZoneBoot.End then DisasterZoneBoot.End(...) end
