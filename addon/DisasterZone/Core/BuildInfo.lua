-- DisasterZone: what is installed on disk. dev/tools/release.py replaces `id` with the build id when it packages a
-- release; in the source tree it stays "dev" (in-game updates never apply to a development copy).
-- assetPack is the number of the art set in this folder: raise it by one whenever art files (.blp / .tga /
-- fonts / sounds) are added or changed, and gate the code that needs the new art with ns:HasAssets(n), so an
-- in-game update can carry that code to members who have not downloaded the new art yet.
-- This file is never part of an in-game update.
DisasterZoneBuild = {
    id = "dev",
    assetPack = 10,
}
