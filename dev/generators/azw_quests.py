"""Azeromon world: the zone's real quests (tbcdb quest_template) for the quest engine (World/Quests.lua).

quests_for(npc_entries, object_entries) -> list of quest dicts:
    id, title, lvl, min, giver / ender (creature entries; goGiver / goEnder for objects), prev (quest that must be
    done first), excl (exclusive group), classes (RequiredClasses mask, 0 = any), text (Details), goal (Objectives),
    done (OfferRewardText), ask (RequestItemsText),
    kill = { { entry, count, name } }, items = { { id, count, name, from = { { entry | -goEntry, chance% } } } },
    money (copper), xp, reward items (names).
Only quests a human can take (RequiredRaces 0 or containing Human)."""
import tbcdb

HUMAN = 1


def _item_sources(db, item):
    """creatures (entry, chance) and objects (-entry, chance) that drop the quest item."""
    out = []
    ct = db.tables["creature_template"]
    cols = ct["cols"]
    li, ei = cols.index("LootId"), cols.index("Entry")
    by_loot = {}
    for row in ct["rows"]:
        if row[li]:
            by_loot.setdefault(row[li], []).append(row[ei])
    for r in db.rows("creature_loot_template"):
        if r["item"] == item:
            ch = abs(r["ChanceOrQuestChance"]) or 100
            for e in by_loot.get(r["entry"], []):
                out.append((e, ch))
    gt = db.index("gameobject_template", "entry")
    go_by_loot = {}
    for e, t in gt.items():
        if t["type"] == 3 and t["data1"]:
            go_by_loot.setdefault(t["data1"], []).append(e)
    for r in db.rows("gameobject_loot_template"):
        if r["item"] == item:
            ch = abs(r["ChanceOrQuestChance"]) or 100
            for e in go_by_loot.get(r["entry"], []):
                out.append((-e, ch))
    return out


def quests_for(npcs, objects=()):
    db = tbcdb.load()
    qt = db.index("quest_template", "entry")
    starts, ends = {}, {}
    for r in db.rows("creature_questrelation"):
        if r["id"] in npcs:
            starts.setdefault(r["quest"], ("npc", r["id"]))
    for r in db.rows("creature_involvedrelation"):
        if r["id"] in npcs:
            ends.setdefault(r["quest"], ("npc", r["id"]))
    for r in db.rows("gameobject_questrelation"):
        if r["id"] in objects:
            starts.setdefault(r["quest"], ("obj", r["id"]))
    for r in db.rows("gameobject_involvedrelation"):
        if r["id"] in objects:
            ends.setdefault(r["quest"], ("obj", r["id"]))
    # an ender elsewhere still counts (Report to Goldshire ends in Goldshire): look it up in the whole table
    any_end = {}
    for r in db.rows("creature_involvedrelation"):
        any_end.setdefault(r["quest"], r["id"])
    items = db.index("item_template", "entry")
    ct = db.index("creature_template", "Entry")
    gt = db.index("gameobject_template", "entry")
    out = []
    for qid in sorted(set(starts) | set(ends)):
        q = qt.get(qid)
        if not q:
            continue
        races = q["RequiredRaces"] or 0
        if races and not races & HUMAN:
            continue
        d = {"id": qid, "title": q["Title"], "lvl": q["QuestLevel"], "min": q["MinLevel"],
             "prev": q["PrevQuestId"] or None, "excl": q["ExclusiveGroup"] or None,
             "classes": q["RequiredClasses"] or None, "text": q["Details"] or None, "goal": q["Objectives"] or None,
             "done": q["OfferRewardText"] or None, "ask": q["RequestItemsText"] or None,
             "money": max(0, q["RewOrReqMoney"] or 0) or None}
        if qid in starts:
            kind, e = starts[qid]
            d["giver" if kind == "npc" else "goGiver"] = e
        end = ends.get(qid)
        if end:
            d["ender" if end[0] == "npc" else "goEnder"] = end[1]
        elif qid in any_end:
            d["ender"] = any_end[qid]
            d["enderName"] = ct[any_end[qid]]["Name"] if any_end[qid] in ct else None
        kill = []
        for i in range(1, 5):
            e, n = q["ReqCreatureOrGOId%d" % i], q["ReqCreatureOrGOCount%d" % i]
            if e and n:
                name = ct[e]["Name"] if e > 0 and e in ct else (gt[-e]["name"] if -e in gt else "?")
                kill.append({"entry": e, "count": n, "name": name, "text": q["ObjectiveText%d" % i] or None})
        if kill:
            d["kill"] = kill
        req = []
        for i in range(1, 5):
            it, n = q["ReqItemId%d" % i], q["ReqItemCount%d" % i]
            if it and n:
                req.append({"id": it, "count": n, "name": items[it]["name"] if it in items else "?",
                            "from": [list(x) for x in _item_sources(db, it)]})
        if req:
            d["items"] = req
        rew = []
        for i in range(1, 5):
            it, n = q["RewItemId%d" % i], q["RewItemCount%d" % i]
            if it and n:
                rew.append(items[it]["name"] if it in items else "?")
        if rew:
            d["rewards"] = rew
        out.append(d)
    return out
