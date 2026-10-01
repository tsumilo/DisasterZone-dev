"""Shared helpers for the Members tab / professions suites (real DisasterZone addon + tools/harness.py)."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import World, Client, case, run_all  # noqa: E402,F401

REALM = "Thunderstrike"

# a few real TBC recipes: (name, spell, item or None)
ALCHEMY = [("Flask of Fortification", 28587, 22851), ("Flask of Mighty Restoration", 28588, 22853),
           ("Super Mana Potion", 28555, 22832), ("Elixir of Major Agility", 28553, 22831),
           ("Transmute: Primal Might", 29688, 23571)]
TAILORING = [("Spellstrike Hood", 31456, 24266), ("Spellstrike Pants", 31455, 24262), ("Netherweave Bag", 26746, 21841)]
ENCHANTING = [("Enchant Weapon - Mongoose", 27984, None), ("Enchant Chest - Exceptional Stats", 27960, None),
              ("Enchant Boots - Boar's Speed", 34008, None)]


def K(name):
    return "%s-%s" % (name, REALM)


def set_skills(cl, skills, collapsed=False):
    """skills: [(name, rank, max)]. Fires SKILL_LINES_CHANGED."""
    cl.eval("""
      local list, collapsed = ...
      local out = { { name = "Professions", header = true, collapsed = collapsed or nil } }
      for _, s in ipairs(list) do out[#out + 1] = { name = s[1], rank = s[2], max = s[3] } end
      out[#out + 1] = { name = "Weapon Skills", header = true }
      out[#out + 1] = { name = "Swords", rank = 350, max = 350 }
      __MOCK.skills = out""", [list(s) for s in skills], collapsed)
    cl.fire("SKILL_LINES_CHANGED")


def _rows(recipes, header=None):
    rows = []
    if header:
        rows.append({"name": header, "header": True})
    for name, spell, item in recipes:
        row = {"name": name, "spell": spell}
        if item:
            row["item"] = item
        rows.append(row)
    return rows


def open_tradeskill(cl, name, recipes, rank=375, max_rank=375, linked=None, header="Recipes"):
    cl.eval("local name, rank, max, rows, linked = ...; __MOCK.tradeskill = { name = name, rank = rank, max = max,"
            " rows = rows, linked = linked }", name, rank, max_rank, _rows(recipes, header), linked)
    cl.fire("TRADE_SKILL_SHOW")


def open_craft(cl, name, recipes, rank=375, max_rank=375, noline=False):
    cl.eval("local name, rank, max, rows, noline = ...; __MOCK.craft = { name = name, rank = rank, max = max,"
            " rows = rows, noline = noline or nil }", name, rank, max_rank, _rows(recipes), noline)
    cl.fire("CRAFT_SHOW")


def member(cl, name):
    """{profId: {rank, max, spec, recipes, total, synced}} as `cl` knows `name`, or None."""
    rows = cl.eval_py("return ns.Professions:GetMember(...)", K(name))
    if rows is None:
        return None
    return {int(r["id"]): r for r in rows}


def crafters(cl, spell):
    r = cl.eval_py("local r = ns.Professions:GetRecipe(...); return r and r.crafters", spell)
    return sorted(r) if r else []


def teach_names(cl):
    """The mock client knows no spell names: give it the ones of the test recipes."""
    for name, spell, _ in ALCHEMY + TAILORING + ENCHANTING + [("Elixir of Major Defense", 28557, 22834)]:
        cl.eval("__MOCK.SPELL_NAMES[...] = select(2, ...)", spell, name)


def join(w, name, cls="PRIEST", rank=3, skills=()):
    """A client that logs in now. Every real character has skill lines (weapon skills), so `skills` defaults to a
    character without professions."""
    cl = Client(w, name, class_file=cls, guild_rank=rank)
    cl.load_addon()
    teach_names(cl)
    set_skills(cl, list(skills))
    return cl


def guild(names, tick=3.0):
    """names: [(name, class)] -> world, {name: client}; everyone loaded and logged in, without professions."""
    w = World()
    c = {}
    for i, (name, cls) in enumerate(names):
        c[name] = Client(w, name, class_file=cls, guild_rank=0 if i == 0 else 3)
    for x in c.values():
        x.load_addon()
        teach_names(x)
        set_skills(x, [])
    w.tick(tick)
    return w, c
