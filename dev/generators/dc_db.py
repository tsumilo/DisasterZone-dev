"""Disastercraft's view of the cMaNGOS TBC world database (dev/art/tbcdb/tbcdb.sql, see tbcdb.py): the player-side
tables tbcdb.py does not keep (classes, level stats, start gear, spells, trainers, creature class-level stats),
parsed once into dev/art/tbcdb/dc_tables.pickle.

    import dc_db
    db = dc_db.load()          # a tbcdb.DB: rows / index / multi
"""
import os
import pickle

import tbcdb

TABLES = {
    "playercreateinfo", "playercreateinfo_action", "playercreateinfo_item", "playercreateinfo_spell",
    "playercreateinfo_skills", "player_classlevelstats", "player_levelstats", "player_xp_for_level",
    "spell_template", "spell_chain", "spell_learn_spell", "spell_threat", "npc_trainer", "npc_trainer_template",
    "creature_template_classlevelstats", "creature_template", "creature_loot_template", "reference_loot_template",
    "item_template", "npc_vendor", "npc_vendor_template", "creature_equip_template", "creature_template_spells",
    "creature_spell_list", "creature_spell_list_entry", "creature_ai_scripts", "exploration_basexp",
    "gameobject_loot_template", "item_loot_template", "quest_template", "world_safe_locs", "game_graveyard_zone",
    "creature_onkill_reputation", "trainer_greeting",
}
CACHE = os.path.join(tbcdb.DIR, "dc_tables.pickle")
_DB = None


def load():
    global _DB
    if _DB is None:
        if os.path.exists(CACHE) and os.path.getmtime(CACHE) >= os.path.getmtime(tbcdb.SQL):
            tables = pickle.load(open(CACHE, "rb"))
        else:
            keep = tbcdb.TABLES
            tbcdb.TABLES = TABLES
            try:
                tables = tbcdb._parse()
            finally:
                tbcdb.TABLES = keep
            pickle.dump(tables, open(CACHE, "wb"), protocol=pickle.HIGHEST_PROTOCOL)
        _DB = tbcdb.DB(tables)
    return _DB


if __name__ == "__main__":
    db = load()
    for t in sorted(db.tables):
        print(t, len(db.tables[t]["rows"]), db.tables[t]["cols"][:14])
