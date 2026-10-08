"""The cMaNGOS TBC world database (github.com/cmangos/tbc-db, Full_DB/TBCDB_1.11.0_*.sql.gz, downloaded 2026-10-08 with
the user's OK into the git-ignored dev/art/tbcdb): spawn points, creature and object templates, quests and their
givers, gossip texts. The SQL dump is parsed once into dev/art/tbcdb/tables.pickle ({table: {"cols": [...], "rows":
[tuple, ...]}}), only for the tables listed in TABLES.

    import tbcdb
    db = tbcdb.load()
    for row in db.rows("creature"): row["id"], row["position_x"] ...

Coordinates are the server's world coordinates (map 0 = Eastern Kingdoms, x north, y west, z up), the same frame as
the client's ADT files (see gen_azeromon_world.py)."""
import os
import pickle
import re

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.path.join(HERE, "..", "art", "tbcdb")
SQL = os.path.join(DIR, "tbcdb.sql")
CACHE = os.path.join(DIR, "tables.pickle")

TABLES = {
    "creature", "creature_template", "creature_addon", "creature_template_addon", "creature_questrelation",
    "creature_involvedrelation", "creature_movement", "creature_movement_template", "creature_spawn_entry",
    "creature_model_info", "gameobject", "gameobject_template", "gameobject_questrelation",
    "gameobject_involvedrelation", "gameobject_spawn_entry", "quest_template", "npc_gossip", "npc_text",
    "gossip_menu", "gossip_menu_option", "broadcast_text", "questgiver_greeting", "page_text", "points_of_interest",
    "game_event_creature", "game_event_gameobject", "pool_creature", "pool_gameobject", "pool_template",
    "npc_vendor", "npc_vendor_template", "npc_trainer", "creature_loot_template", "item_template",
    "gameobject_loot_template", "reference_loot_template",
    "areatrigger_teleport", "game_graveyard_zone", "script_texts", "dbscripts_on_quest_start",
    "dbscripts_on_quest_end", "creature_linking", "spawn_group", "spawn_group_spawn", "creature_spell_list",
}


def _values(s, i):
    """Parses `(v, v, ...),(...)...;` from s[i:]; yields tuples. Strings are MySQL-escaped, numbers become int/float,
    NULL becomes None."""
    n = len(s)
    out = []
    while i < n:
        c = s[i]
        if c == "(":
            row = []
            i += 1
            while True:
                c = s[i]
                if c == "'":
                    j = i + 1
                    buf = []
                    while True:
                        k = s.find("'", j)
                        b = s.find("\\", j)
                        if b != -1 and b < k:
                            buf.append(s[j:b])
                            e = s[b + 1]
                            buf.append({"n": "\n", "r": "\r", "t": "\t", "0": "\0"}.get(e, e))
                            j = b + 2
                            continue
                        if k + 1 < n and s[k + 1] == "'":
                            buf.append(s[j:k] + "'")
                            j = k + 2
                            continue
                        buf.append(s[j:k])
                        i = k + 1
                        break
                    row.append("".join(buf))
                else:
                    j = i
                    while s[j] not in ",)":
                        j += 1
                    tok = s[i:j].strip()
                    if tok == "NULL":
                        row.append(None)
                    else:
                        try:
                            row.append(int(tok))
                        except ValueError:
                            row.append(float(tok))
                    i = j
                c = s[i]
                i += 1
                if c == ")":
                    break
            out.append(tuple(row))
        elif c == ";":
            return out, i + 1
        else:
            i += 1
    return out, i


def _parse():
    text = open(SQL, encoding="utf-8", errors="replace").read()
    tables = {}
    for m in re.finditer(r"CREATE TABLE `(\w+)` \((.*?)\n\)", text, re.S):
        name = m.group(1)
        if name not in TABLES:
            continue
        cols = re.findall(r"^\s+`(\w+)`", m.group(2), re.M)
        tables[name] = {"cols": cols, "rows": []}
    for m in re.finditer(r"INSERT INTO `(\w+)`(?: \(([^)]*)\))? VALUES", text):
        name = m.group(1)
        if name not in tables:
            continue
        rows, _ = _values(text, m.end())
        t = tables[name]
        if m.group(2):
            cols = [c.strip(" `") for c in m.group(2).split(",")]
            if cols != t["cols"]:
                idx = [cols.index(c) if c in cols else None for c in t["cols"]]
                rows = [tuple(r[k] if k is not None else None for k in idx) for r in rows]
        t["rows"].extend(rows)
    return tables


class DB:
    def __init__(self, tables):
        self.tables = tables
        self._idx = {}

    def cols(self, table):
        return self.tables[table]["cols"]

    def rows(self, table):
        cols = self.tables[table]["cols"]
        for r in self.tables[table]["rows"]:
            yield dict(zip(cols, r))

    def index(self, table, key):
        """{key value: row dict} (last wins)."""
        k = (table, key)
        if k not in self._idx:
            self._idx[k] = {r[key]: r for r in self.rows(table)}
        return self._idx[k]

    def multi(self, table, key):
        """{key value: [row dict, ...]}."""
        k = (table, key, "multi")
        if k not in self._idx:
            d = {}
            for r in self.rows(table):
                d.setdefault(r[key], []).append(r)
            self._idx[k] = d
        return self._idx[k]


_DB = None


def load():
    global _DB
    if _DB is None:
        if os.path.exists(CACHE) and os.path.getmtime(CACHE) >= os.path.getmtime(SQL):
            tables = pickle.load(open(CACHE, "rb"))
        else:
            tables = _parse()
            pickle.dump(tables, open(CACHE, "wb"), protocol=pickle.HIGHEST_PROTOCOL)
        _DB = DB(tables)
    return _DB


if __name__ == "__main__":
    db = load()
    for t in sorted(db.tables):
        print(t, len(db.tables[t]["rows"]), db.tables[t]["cols"][:12])
