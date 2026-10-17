-- DisasterZone game pack: the last file in the TOC (dev/docs/GAME_PACKS.md). Starts the pack's modules: they were
-- made after DisasterZone's own start (Core/Init.lua ns:PackLoaded). Never part of an in-game update.
if DisasterZone and DisasterZone.PackLoaded then DisasterZone:PackLoaded(...) end
