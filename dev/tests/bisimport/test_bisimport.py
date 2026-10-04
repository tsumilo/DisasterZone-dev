"""BiS import / export (Core/Codec.lua, Core/BiSImport.lua, Core/BiSExport.lua, UI/ImportExport.lua).

Covers: the codec (JSON with escapes / null positions / errors, base64 in both alphabets, CSV with quotes and line
breaks); every import format (That's My BiS CSV - my character picked out of the guild, ranks, off spec, received,
prio rows ignored, the line breaks lost on a big paste; Sixty Upgrades; WoWSims addon / sim / bulk JSON; Wowhead
gear planner links; item links, Wowhead item links, numbers and names); fitting into slots (main then alt, rings and
trinkets filling both slots' mains first, one-handers off the off hand for classes without dual wield, tier tokens
by the spec's bundled lists, what doesn't fit and why); Fill / Replace / disabled slots / the raid lock; the exports
(the WowSimsExporter JSON from my gear with enchants, gems, talents in tier order, professions; a BiS phase keeping
worn gems; the Bulk list; the Wowhead link checked against a port of the reader WoWSims uses); the window (Import /
Export in My BiS's More menu, the preview, a big paste collected from OnChar, the export tab's choices).

Run: luaenv\\Scripts\\python.exe tests\\bisimport\\test_bisimport.py [-k name]
"""
import base64
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import (case, run_all, solo, no_errors, install_helpers, strip_codes, menu_texts,  # noqa: E402
                     menu_pick)

# Karazhan / phase 1 items (Data/Items.lua)
GREATHELM = 28593     # Eternium Greathelm: head
WITCH_HAT = 28586     # Wicked Witch's Hat: head
SPECTRAL = 28510      # Spectral Band of Innervation: ring
GARONA = 28649        # Garona's Signet Ring: ring
MENDER = 28661        # Mender's Heart-Ring: ring
SHERMANAR = 28675     # Shermanar Great-Ring: ring
WATCH = 28528         # Moroes' Lucky Pocket Watch: trinket
RIBBON = 28590        # Ribbon of Sacrifice: trinket
DESPAIR = 28573       # Despair: two-hander
SPITEBLADE = 28729    # Spiteblade: one-hander (paladins can't put it in the off hand)
TRIPTYCH = 28754      # Triptych Shield of the Ancients: shield
HANDWRAPS = 28507     # Handwraps of Flowing Thought: hands
SAINTLY = 28508       # Gloves of Saintly Blessings: hands
NECKLACE = 28509      # Worgen Claw Necklace: neck
IDOL = 28568          # Idol of the Avian Heart: druid relic
CHAMPION_HELM = 29760  # Helm of the Fallen Champion (T4 token: paladin / rogue / shaman)

TMB_HEADER = ("type,raid_group_name,member_name,character_name,character_class,character_is_alt,"
              "character_inactive_at,character_note,sort_order,item_name,item_id,is_offspec,note,received_at,"
              "import_id,item_note,item_prio_note,item_tier,item_tier_label,created_at,updated_at")


def tmb_row(kind, char, cls, order, name, item, os_=0, note="", received="", updated=""):
    q = lambda s: '"' + s.replace('"', '""') + '"'   # noqa: E731
    return ",".join([kind, "Main", "member", char, cls, "0", "", "", str(order), q(name), str(item), str(os_),
                     q(note) if note else "", q(received) if received else "", "", "", "", "", "",
                     q("2026-10-01 20:00:00"), q(updated) if updated else ""])


def tmb_csv():
    rows = [
        # out of order on purpose: sort_order decides
        tmb_row("wishlist", "Alice", "Paladin", 3, "Spectral Band of Innervation", SPECTRAL),
        tmb_row("wishlist", "Alice", "Paladin", 1, "Eternium Greathelm", GREATHELM, note="first, \"best\"\nreally"),
        tmb_row("wishlist", "Alice", "Paladin", 2, "Wicked Witch's Hat", WITCH_HAT, updated="2026-10-02 21:00:00"),
        tmb_row("wishlist", "Alice", "Paladin", 4, "Garona's Signet Ring", GARONA),
        tmb_row("wishlist", "Alice", "Paladin", 5, "Mender's Heart-Ring", MENDER),
        tmb_row("wishlist", "Alice", "Paladin", 6, "Shermanar Great-Ring", SHERMANAR),
        tmb_row("wishlist", "Alice", "Paladin", 7, "Moroes' Lucky Pocket Watch", WATCH),
        tmb_row("wishlist", "Alice", "Paladin", 8, "Despair, the big one", DESPAIR),
        tmb_row("wishlist", "Alice", "Paladin", 9, "Spiteblade", SPITEBLADE),
        tmb_row("wishlist", "Alice", "Paladin", 10, "Triptych Shield of the Ancients", TRIPTYCH),
        tmb_row("wishlist", "Alice", "Paladin", 11, "Handwraps of Flowing Thought", HANDWRAPS, os_=1),
        tmb_row("wishlist", "Alice", "Paladin", 12, "Idol of the Avian Heart", IDOL),
        tmb_row("prio", "Alice", "Paladin", 1, "Ribbon of Sacrifice", RIBBON),
        tmb_row("received", "Alice", "Paladin", 0, "Spectral Band of Innervation", SPECTRAL, received="2026-09-30"),
        tmb_row("received", "Alice", "Paladin", 0, "Handwraps of Flowing Thought", HANDWRAPS, received="2026-09-30"),
        tmb_row("received", "Alice", "Paladin", 0, "Worgen Claw Necklace", NECKLACE, received="2026-09-30"),
        tmb_row("wishlist", "Bob", "Rogue", 1, "Garona's Signet Ring", GARONA),
    ]
    return TMB_HEADER + "\r\n" + "\r\n".join(rows) + "\r\n"


LUA = r"""
function T_parse(text)
  local p, err = ns.BiSImport:Parse(text)
  if not p then return { err = err or "" } end
  local out = { format = p.format, label = p.label, class = p.class or "", n = p.items and #p.items or 0, items = {} }
  for i, e in ipairs(p.items or {}) do out.items[i] = { e.id, e.sid or 0 } end
  if p.format == "tmb" then
    out.characters = p.characters
    out.default = ns.BiSImport:DefaultCharacter(p) or ""
  end
  return out
end
-- the plan as { ms = { [sid] = { main, alt } }, os = ..., unplaced = { { id, why } }, received = { ids } }
function T_plan(text, opts)
  local p = assert(ns.BiSImport:Parse(text))
  local plan = ns.BiSImport:Plan(p, opts or {})
  local out = { unplaced = {}, received = plan.received, count = plan.count }
  for list, slots in pairs(plan.lists) do
    out[list] = {}
    for sid, t in pairs(slots) do out[list][tostring(sid)] = { t[1], t[2] } end
  end
  for i, u in ipairs(plan.unplaced) do out.unplaced[i] = { u.id, u.why, u.list } end
  return out
end
function T_slot(phase, sid, list)
  local m, a = ns.BiS:GetSlot(phase, sid, list)
  return { m or 0, a or 0 }
end
-- the equipped item links (slot -> link) and talents the client reports
function T_fake_links(map)
  local orig = GetInventoryItemLink
  GetInventoryItemLink = function(unit, slot)
    if unit == "player" and map[slot] then return map[slot] end
    return orig(unit, slot)
  end
end
function T_fake_talents(tabs)
  GetNumTalentTabs = function() return #tabs end
  GetNumTalents = function(tab) return #(tabs[tab] or {}) end
  GetTalentInfo = function(tab, i)
    local t = tabs[tab] and tabs[tab][i]
    if not t then return nil end
    return "Talent" .. tab .. "." .. i, 1, t[1], t[2], t[3], 5, false, true
  end
end
-- a paste as WoW delivers it: the box keeps what fits (SetMaxBytes), OnChar fires for every character
function T_paste(eb, text)
  __MOCK.type_text(eb, text)
  local onChar = eb:GetScript("OnChar")
  for i = 1, #text do onChar(eb, text:sub(i, i)) end
end
"""


def setup(name="Alice", class_file="PALADIN", **kw):
    w, c = solo(name, class_file=class_file, guild_rank=3, tick=4, council=[], **kw)
    install_helpers(c)
    c.eval(LUA)
    return w, c


def parse(c, text):
    return c.eval_py("return T_parse(...)", text)


def plan(c, text, **opts):
    return c.eval_py("local t, o = ...; return T_plan(t, o)", text, opts or {})


def slot(c, phase, sid, lst=None):
    return list(c.eval_py("local p, s, l = ...; return T_slot(p, s, l)", phase, sid, lst))


def picks(pl, lst, sid):
    t = (pl.get(lst) or {}).get(str(sid))
    return list(t) if t else [0, 0]


# ------------------------------------------------------------------------------------------------------------------
# Codec

@case
def codec_json_decodes_escapes_null_positions_and_reports_errors():
    w, c = setup()
    r = c.eval_py(r"""local C = ns.Codec
      local v = assert(C.JSONDecode([[{"a":[1,null,3],"s":"q\"\\\/\né😀","t":true,"f":false,"n":-1.5e2,"o":{}}]]))
      return { #v.a, v.a[2] == C.NULL, v.a[3], v.s, v.t, v.f, v.n, next(v.o) == nil }""")
    assert r[0] == 3 and r[1] is True and r[2] == 3, r
    assert r[3] == 'q"\\/\né\U0001F600', repr(r[3])
    assert r[4] is True and r[5] is False and r[6] == -150 and r[7] is True, r
    errs = c.eval_py("""local C = ns.Codec
      local out = {}
      for i, s in ipairs({ '{"a":1', '[1,2', '{"a" 1}', '"open', '[1] x', '{"a":tru}' }) do
        local v, err = C.JSONDecode(s)
        out[i] = { v == nil, err or "" }
      end
      return out""")
    assert all(e[0] for e in errs) and all(e[1] for e in errs), errs
    # encode -> decode keeps everything; objects come out with sorted names, null in arrays
    enc = c.eval(r"""local C = ns.Codec
      return C.JSONEncode({ b = { 1, C.NULL, "x\"y" }, a = { k = true }, e = {}, n = 0.25 })""")
    assert enc == '{"a":{"k":true},"b":[1,null,"x\\"y"],"e":[],"n":0.25}', enc
    assert json.loads(enc)["b"] == [1, None, 'x"y']
    no_errors(w)


@case
def codec_base64_both_alphabets_and_csv_quotes():
    w, c = setup()
    data = list(range(256)) + [251, 255, 254]
    std, url = c.eval_py("local b = ...; return { ns.Codec.Base64Encode(b), ns.Codec.Base64Encode(b, true) }", data)
    assert std == base64.b64encode(bytes(data)).decode(), std
    assert url == base64.urlsafe_b64encode(bytes(data)).decode().rstrip("="), url
    back = c.eval_py("local s = ...; return ns.Codec.Base64Decode(s)", url)
    assert list(back) == data
    assert c.eval("return ns.Codec.Base64Decode('ab$c') == nil")
    rows = c.eval_py(r"""return ns.Codec.ParseCSV('\239\187\191a,"b,1","c ""q""\nline"\r\n,,\nlast,"x"')""")
    assert [list(r) for r in rows] == [["a", "b,1", 'c "q"\nline'], ["", "", ""], ["last", "x"]], rows
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# That's My BiS

@case
def tmb_csv_picks_me_out_of_the_guild_in_rank_order():
    w, c = setup()
    p = parse(c, tmb_csv())
    assert p["format"] == "tmb" and p["label"] == "That's My BiS", p
    assert list(p["characters"]) == ["Alice", "Bob"] and p["default"] == "Alice", p
    pl = plan(c, tmb_csv(), character="Alice")
    assert picks(pl, "ms", 1) == [GREATHELM, WITCH_HAT], pl          # ranks 1 and 2
    assert picks(pl, "ms", 11) == [SPECTRAL, MENDER], pl             # rings: both mains first
    assert picks(pl, "ms", 12) == [GARONA, SHERMANAR], pl
    assert picks(pl, "ms", 13) == [WATCH, 0], pl
    assert picks(pl, "ms", 15) == [DESPAIR, SPITEBLADE], pl          # a paladin's one-hander stays off the off hand
    assert picks(pl, "ms", 16) == [TRIPTYCH, 0], pl
    assert picks(pl, "os", 7) == [HANDWRAPS, 0], pl                  # is_offspec = 1
    assert picks(pl, "ms", 7) == [0, 0], pl
    # the druid idol: my class can't use it; the prio row is not a wish
    assert [list(u)[:2] for u in pl["unplaced"]] == [[IDOL, "class"]], pl["unplaced"]
    assert RIBBON not in [picks(pl, "ms", 13)[0], picks(pl, "ms", 14)[0]]
    # received and on the plan (the necklace is not on the wishlist)
    assert sorted(pl["received"]) == sorted([SPECTRAL, HANDWRAPS]), pl["received"]
    # somebody else's list
    bob = plan(c, tmb_csv(), character="Bob")
    assert picks(bob, "ms", 11) == [GARONA, 0] and not bob.get("os"), bob
    no_errors(w)


@case
def tmb_csv_without_line_breaks_reads_the_same():
    w, c = setup()
    glued = tmb_csv().replace("\r\n", "").replace("\n", " ")   # every line break lost, in notes too
    assert "\n" not in glued
    a = plan(c, tmb_csv(), character="Alice")
    b = plan(c, glued, character="Alice")
    assert a == b, (a, b)
    # the glued header still names the columns
    p = parse(c, glued)
    assert list(p["characters"]) == ["Alice", "Bob"], p
    no_errors(w)


@case
def tmb_errors_and_somebody_elses_name():
    w, c = setup("Carol")
    p = parse(c, tmb_csv())
    assert p["default"] == "", p   # Carol isn't in the export: she picks a character
    only_header = parse(c, TMB_HEADER + "\n")
    assert "no wishlists" in only_header["err"], only_header
    no_errors(w)


@case
def tier_tokens_take_the_piece_of_my_spec():
    w, c = setup()
    csv_text = TMB_HEADER + "\n" + tmb_row("wishlist", "Alice", "Paladin", 1, "Helm of the Fallen Champion",
                                           CHAMPION_HELM) + "\n"
    # no spec chosen: a paladin's Champion helm is one of three sets
    c.eval("ns.BiS:GetData().sp = ''")
    pl = plan(c, csv_text, character="Alice")
    assert [list(u)[:2] for u in pl["unplaced"]] == [[CHAMPION_HELM, "tokenspec"]], pl
    c.eval("ns.BiS:SetSpec('Holy')")
    want = c.eval_py("""local token = ...
      local hits = {}
      local set = {}
      for p = 1, 5 do
        for _, e in pairs(ns.Loon:GetTemplate('PALADIN', 'Holy', p) or {}) do
          for _, id in ipairs(e) do set[id] = true end
        end
      end
      for _, piece in ipairs(ns.Data.Tokens[token]) do
        if ns.Data.TierPieceClass[piece] == 'PALADIN' and ns.ItemDB:FitsSlot(piece, 1) and set[piece] then hits[#hits + 1] = piece end
      end
      return hits""", CHAMPION_HELM)
    assert len(want) == 1, want
    pl = plan(c, csv_text, character="Alice")
    assert picks(pl, "ms", 1) == [want[0], 0] and not pl["unplaced"], pl
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# JSON sets, Wowhead links, item lists

@case
def sixty_upgrades_set_uses_its_slots_and_says_whose_set_it_is():
    w, c = setup()
    doc = {"character": {"name": "Alice", "gameClass": "PALADIN", "race": "HUMAN"},
           "items": [{"id": GREATHELM, "name": "Eternium Greathelm", "slot": "HEAD", "enchant": {"id": 3003},
                      "gems": [{"id": 24030}]},
                     {"id": GARONA, "slot": "FINGER_2"}, {"id": SPECTRAL, "slot": "FINGER_1"},
                     {"id": RIBBON, "slot": "TRINKET_2"}, {"id": TRIPTYCH, "slot": "OFF_HAND"}],
           "talents": [{"spellId": 1}]}
    p = parse(c, json.dumps(doc))
    assert p["format"] == "sixty" and p["class"] == "PALADIN" and p["n"] == 5, p
    pl = plan(c, json.dumps(doc))
    assert picks(pl, "ms", 11) == [SPECTRAL, 0] and picks(pl, "ms", 12) == [GARONA, 0], pl
    assert picks(pl, "ms", 14) == [RIBBON, 0] and picks(pl, "ms", 13) == [0, 0], pl
    assert picks(pl, "ms", 16) == [TRIPTYCH, 0], pl
    # into the off-spec list when asked
    os_pl = plan(c, json.dumps(doc), list="os")
    assert picks(os_pl, "os", 1) == [GREATHELM, 0] and not os_pl.get("ms"), os_pl
    doc["character"]["gameClass"] = "ROGUE"
    assert parse(c, json.dumps(doc))["class"] == "ROGUE"
    assert "couldn't be read" in parse(c, '{"items": [1,')["err"]
    no_errors(w)


@case
def wowsims_sim_export_and_bulk_lists():
    w, c = setup()
    items = [{} for _ in range(17)]
    items[0] = {"id": GREATHELM, "enchant": 3003, "gems": [24030, 0]}
    items[12] = {"id": RIBBON}          # trinket 2 position... index 12 is trinket 1
    items[13] = {"id": WATCH}
    sim = {"player": {"name": "Alice", "race": "RaceHuman", "class": "ClassPaladin",
                      "equipment": {"items": items}}, "settings": {"iterations": 3000}}
    p = parse(c, json.dumps(sim))
    assert p["format"] == "wowsims" and p["class"] == "PALADIN", p
    assert sorted(map(tuple, p["items"])) == sorted([(GREATHELM, 1), (RIBBON, 13), (WATCH, 14)]), p
    pl = plan(c, json.dumps(sim))
    assert picks(pl, "ms", 13) == [RIBBON, 0] and picks(pl, "ms", 14) == [WATCH, 0], pl
    # a raid export: the first player with gear
    raid = {"raid": {"parties": [{"players": [{}, {"class": "ClassPaladin", "equipment": {"items": items}}]}]}}
    assert parse(c, json.dumps(raid))["n"] == 3
    # a Bulk list (no slot order)
    bulk = parse(c, json.dumps({"items": [{"id": WATCH}, {"id": RIBBON}, {"id": SPECTRAL}]}))
    assert bulk["format"] == "wowsims" and [tuple(i) for i in bulk["items"]] == [(WATCH, 0), (RIBBON, 0), (SPECTRAL, 0)]
    # a plain JSON array of item numbers
    arr = parse(c, json.dumps([GREATHELM, SPECTRAL]))
    assert arr["format"] == "items" and arr["n"] == 2, arr
    no_errors(w)


@case
def item_lists_read_links_wowhead_urls_numbers_and_names():
    w, c = setup()
    link = c.eval("return __MOCK.item_link(...)", GREATHELM)
    text = "\n".join([
        "My list for P1:",
        "  " + link,
        "https://www.wowhead.com/tbc/item=%d/spectral-band-of-innervation" % SPECTRAL,
        "%d, %d" % (GARONA, 2026),          # 2026 isn't something to wear
        "[Moroes' Lucky Pocket Watch]",
        "Trinket\tRibbon of Sacrifice\tMoroes",   # a table copied from a guide
        "1. Worgen Claw Necklace (Prince)",
        "level 70 notes",
    ])
    p = parse(c, text)
    assert p["format"] == "items", p
    assert [i[0] for i in p["items"]] == [GREATHELM, SPECTRAL, GARONA, WATCH, RIBBON, NECKLACE], p["items"]
    assert "Nothing to import" in parse(c, "hello there\nnothing here")["err"]
    assert parse(c, "   \n ") == {"err": ""}
    no_errors(w)


def wh_read(link):
    """The Wowhead gear planner reader WoWSims uses (ui/features/import-export/importers/wowhead_gear_planner.ts)."""
    tail = link.split("gear-planner/", 1)[1]
    cls, race, h = tail.split("/")
    s = h.replace("-", "+").replace("_", "/")
    s += "=" * (-len(s) % 4)
    b = list(base64.b64decode(s))
    r = b.pop(0)
    out = {"class": cls, "race": race, "version": r, "level": b.pop(0) if r > 0 else None, "talents": "", "items": []}
    if r > 1:
        e = b.pop(0)
        a, b = b[:e], b[e:]
        nib = []
        for x in a:
            nib += [x >> 4, x & 15]
        n, t = 0, ""
        for v in nib:
            if n >= 3:
                break
            if v == 15:
                t += "-"
                n += 1
            else:
                t += str(v)
        out["talents"] = t.rstrip("-")
    while len(b) >= 3:
        slot = b.pop(0)
        gems = iid = 0
        if r >= 3:
            e = b.pop(0)
            gems = (e & 224) >> 5
            iid |= (e & 31) << 16
        iid |= b.pop(0) << 8
        iid |= b.pop(0)
        item = {"slot": slot & ~(128 | 64), "id": iid, "gems": []}
        if slot & 128:
            item["enchant"] = (b.pop(0) << 8) | b.pop(0)
        if slot & 64:
            v = (b.pop(0) << 8) | b.pop(0)
            item["random"] = v - 65536 if v & 32768 else v
        for _ in range(gems):
            s0 = b.pop(0)
            item["gems"].append(((s0 & 31) << 16) | (b.pop(0) << 8) | b.pop(0))
        out["items"].append(item)
    return out


def gear_with_gems(c):
    """Equip head (enchanted, 2 gems), a ring with a random suffix, a trinket; talents in shuffled index order."""
    c.equip({1: GREATHELM, 11: SPECTRAL, 13: WATCH, 16: DESPAIR})
    c.eval("""T_fake_links({
      [1] = "|cffa335ee|Hitem:%d:3003:24030:0:24051:::::70:::::|h[Eternium Greathelm]|h|r",
      [11] = "|cffa335ee|Hitem:%d::::::-19::70:::::|h[Spectral Band]|h|r",
    })""" % (GREATHELM, SPECTRAL))
    c.eval("""T_fake_talents({
      { { 2, 1, 3 }, { 1, 2, 5 }, { 1, 1, 0 } },
      { { 1, 1, 2 } },
      {},
    })""")
    c.eval("""ns.Professions.GetMember = function() return { { id = 186, rank = 375 }, { id = 185, rank = 300 },
      { id = 755, rank = 360 } } end""")


@case
def wowsims_export_matches_the_exporter_addon():
    w, c = setup()
    gear_with_gems(c)
    text = c.eval("return ns.BiSExport:WoWSims(ns.BiSExport:EquippedSpecs())")
    doc = json.loads(text)
    assert doc["class"] == "paladin" and doc["race"] == "Human" and doc["level"] == 70, doc
    assert doc["talents"] == "053-2-", doc["talents"]   # tier then column order, every tree
    assert doc["professions"] == [{"name": "Mining", "level": 375}, {"name": "Jewelcrafting", "level": 360}], doc
    assert doc["version"].startswith("DisasterZone "), doc["version"]
    items = doc["gear"]["items"]
    assert len(items) == 17, items
    assert items[0] == {"id": GREATHELM, "enchant": 3003, "gems": [24030, 0, 24051]}, items[0]
    assert items[10] == {"id": SPECTRAL, "random_suffix": -19}, items[10]
    assert items[12] == {"id": WATCH} and items[14] == {"id": DESPAIR}, items
    assert items[1] is None and items[16] is None, items
    # importing it back fills the same slots
    p = parse(c, text)
    assert p["format"] == "wowsims" and p["class"] == "PALADIN", p
    assert sorted(map(tuple, p["items"])) == sorted([(GREATHELM, 1), (SPECTRAL, 11), (WATCH, 13), (DESPAIR, 15)])
    no_errors(w)


@case
def phase_export_keeps_worn_gems_and_drops_the_off_hand_under_a_two_hander():
    w, c = setup()
    gear_with_gems(c)
    c.equip({17: TRIPTYCH})
    c.eval("""ns.BiS:ApplyTemplate(1, { [1] = { %d, %d }, [12] = { %d, 0 }, [15] = { %d, 0 }, [13] = { %d, 0 } }, true)""" %
           (GREATHELM, WITCH_HAT, SPECTRAL, DESPAIR, RIBBON))
    specs, kept = c.eval_py("local s, k = ns.BiSExport:PhaseSpecs(1); return { s, k }")
    specs = {int(k): v for k, v in dict(specs).items()}
    assert specs[1]["id"] == GREATHELM and specs[1].get("enchant") == 3003, specs[1]   # worn: gems and enchant
    assert specs[12]["id"] == SPECTRAL and specs[12].get("suffix") == -19, specs[12]   # worn in the other ring slot
    assert specs[13] == {"id": RIBBON}, specs[13]
    assert 16 not in specs, specs                    # two-hander picked: not the shield I wear
    assert specs[11]["id"] == SPECTRAL and kept == 1, (specs, kept)   # empty ring 1 keeps what I wear
    bulk, n = c.eval_py("local t, n = ns.BiSExport:Bulk(1); return { t, n }")
    ids = [i["id"] for i in json.loads(bulk)["items"]]
    assert ids == [GREATHELM, WITCH_HAT, SPECTRAL, RIBBON, DESPAIR] and n == 5, ids
    assert json.loads(bulk)["items"][0].get("gems") == [24030, 0, 24051]
    no_errors(w)


@case
def wowhead_link_reads_like_wowsims_reads_it_and_comes_back():
    w, c = setup()
    gear_with_gems(c)
    link = c.eval("return ns.BiSExport:WowheadLink(ns.BiSExport:EquippedSpecs())")
    assert link.startswith("https://www.wowhead.com/tbc/gear-planner/paladin/human/"), link
    r = wh_read(link)
    assert r["version"] == 3 and r["level"] == 70 and r["talents"] == "053-2", r
    by_slot = {i["slot"]: i for i in r["items"]}
    assert [i["slot"] for i in r["items"]] == sorted(by_slot), r["items"]   # in Wowhead slot order
    assert by_slot[1] == {"slot": 1, "id": GREATHELM, "gems": [24030, 24051]}, by_slot[1]
    assert by_slot[11] == {"slot": 11, "id": SPECTRAL, "gems": [], "random": -19}, by_slot[11]
    assert by_slot[13]["id"] == WATCH and by_slot[16]["id"] == DESPAIR, by_slot
    # and our import reads it back into the same slots
    p = parse(c, "see " + link + " for my set")
    assert p["format"] == "wowhead" and p["class"] == "PALADIN", p
    assert sorted(map(tuple, p["items"])) == sorted([(GREATHELM, 1), (SPECTRAL, 11), (WATCH, 13), (DESPAIR, 15)])
    # undead are "undead" on Wowhead
    c.eval("UnitRace = function() return 'Undead', 'Scourge', 5 end")
    assert "/paladin/undead/" in c.eval("return ns.BiSExport:WowheadLink({})")
    assert "no items yet" in parse(c, "https://www.wowhead.com/tbc/gear-planner/paladin/human")["err"]
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# Applying

@case
def fill_keeps_my_picks_replace_makes_the_phase_the_import():
    w, c = setup()
    c.eval("ns.BiS:ApplyTemplate(1, { [1] = { %d, 0 }, [2] = { %d, 0 } }, true)" % (WITCH_HAT, NECKLACE))
    c.eval("ns.BiS:SetSlotDisabled(1, 13, true)")
    text = tmb_csv()
    rows, fill, rep = c.eval_py("""local t = ...
      local p = ns.BiSImport:Parse(t)
      local plan = ns.BiSImport:Plan(p, { character = 'Alice' })
      local rows, f, r = ns.BiSImport:Preview(plan, 1)
      local out = {}
      for i, x in ipairs(rows) do out[i] = { x.list, x.sid, x.state } end
      return { out, f, r }""", text)
    states = {(r[0], r[1]): r[2] for r in rows}
    assert states[("ms", 1)] == "change" and states[("ms", 2)] == "clear", states
    assert states[("ms", 13)] == "disabled" and states[("ms", 11)] == "new" and states[("os", 7)] == "new", states
    # fill: 11, 12, 15, 16 (ms) + 7 (os); replace adds head and the cleared neck
    assert fill == 5 and rep == 7, (fill, rep)
    n = c.eval("""local t = ...
      local plan = ns.BiSImport:Plan(ns.BiSImport:Parse(t), { character = 'Alice' })
      return ns.BiSImport:Apply(plan, 1, false, true)""", text)
    assert n == 5, n
    assert slot(c, 1, 1) == [WITCH_HAT, 0] and slot(c, 1, 2) == [NECKLACE, 0], "fill keeps my picks"
    assert slot(c, 1, 11) == [SPECTRAL, MENDER] and slot(c, 1, 13) == [0, 0]
    assert slot(c, 1, 7, "os") == [HANDWRAPS, 0] and c.eval("return ns.BiS:HasOffSpec()")
    assert c.eval("return ns.BiS:GetObtainedState(...)", SPECTRAL) == "manual"
    assert c.eval("return ns.BiS:GetObtainedState(...)", NECKLACE) is None   # received, but not on the list
    c.eval("""local t = ...
      local plan = ns.BiSImport:Plan(ns.BiSImport:Parse(t), { character = 'Alice' })
      ns.BiSImport:Apply(plan, 1, true, false)""", text)
    assert slot(c, 1, 1) == [GREATHELM, WITCH_HAT] and slot(c, 1, 2) == [0, 0], "replace"
    no_errors(w)


@case
def locked_lists_refuse_the_import():
    w, c = setup()
    c.eval("""ns.GroupRules.IsLocked = function() return true end
      ns.GroupRules.GetLockInfo = function() return { by = 'Lee-Thunderstrike', at = 1 } end""")
    r = c.eval("""local t = ...
      local plan = ns.BiSImport:Plan(ns.BiSImport:Parse(t), { character = 'Alice' })
      return ns.BiSImport:Apply(plan, 1, true, true)""", tmb_csv())
    assert r is False, r
    assert slot(c, 1, 1) == [0, 0]
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# The window

def open_mybis(c, w):
    c.eval("ns.MainFrame:Open('mybis')")
    w.tick(0.3)


@case
def my_bis_more_menu_opens_the_window():
    w, c = setup()
    open_mybis(c, w)
    more = c.eval("return ns.MainFrame:GetPanel('mybis').moreBtn")
    c.click(more)
    entries = [e[2] for e in menu_texts(c.last_menu()) if e[2]]
    assert [strip_codes(t).strip() for t in entries] == ["Import", "Export", "Clear P1"], entries
    # each entry starts with its atlas icon (import 32, export 33, the bin 12)
    for text, idx in zip(entries, (32, 33, 12)):
        assert text.startswith("|T" + c.eval("return ns.UI.ICON_ATLAS")), text
        col, row = (idx - 1) % 4, (idx - 1) // 4
        assert ":256:1024:%d:%d:%d:%d:" % (col * 64, col * 64 + 64, row * 64, row * 64 + 64) in text, text
    menu_pick(c, "Import")
    w.tick(0.1)
    assert c.eval("return ns.ImportExport:IsOpen()")
    assert c.eval("return ns.ImportExport:GetImportState().tab") == "import"
    c.click(more)
    menu_pick(c, "Export")
    w.tick(0.1)
    assert c.eval("return ns.ImportExport:GetImportState().tab") == "export"
    no_errors(w)


@case
def window_preview_and_fill_with_received_items():
    w, c = setup()
    open_mybis(c, w)
    c.eval("ns.MyBiS:SetPhase(2, true)")
    c.eval("ns.ImportExport:Open('import')")
    c.eval("ns.ImportExport:SetSource(...)", tmb_csv())
    w.tick(0.1)
    st = c.eval_py("local s = ns.ImportExport:GetImportState(); return { s.phase, s.character or '', s.parsed and s.parsed.format or '' }")
    assert st == [2, "Alice", "tmb"], st
    f = c.eval("return ns.ImportExport:GetFrame().import")
    status = strip_codes(c.eval("local f = ...; return f.status:GetText()", f))
    assert "That's My BiS" in status and "2 characters" in status and "Alice: 12 wishlist items" in status, status
    rows = c.eval_py("""local out = {}
      for i, d in ipairs(ns.ImportExport:GetPreviewRows()) do out[i] = d.header and ('# ' .. d.text) or (d.list .. d.sid .. d.state) end
      return out""")
    assert rows[0] == "# Main spec" and "# Off spec" in rows and "ms1new" in rows and "os7new" in rows, rows
    fill_text = c.eval("local f = ...; return f.fill:GetText()", f)
    assert fill_text == "Fill empty slots (7)", fill_text   # head, rings, trinket, weapons + off-spec hands
    assert c.eval("local f = ...; return f.received:IsShown()", f)
    assert "Mark 2 received items as obtained" in c.eval("local f = ...; return f.received.label:GetText()", f)
    assert "1 item not placed" in strip_codes(c.eval("local f = ...; return f.unplaced.fs:GetText()", f))
    c.click(c.eval("local f = ...; return f.fill", f))
    w.tick(0.2)
    assert slot(c, 2, 1) == [GREATHELM, WITCH_HAT] and slot(c, 2, 7, "os") == [HANDWRAPS, 0]
    assert c.eval("return ns.BiS:GetObtainedState(...)", HANDWRAPS) == "manual"
    assert "Done: 7 slots changed in P2 (main and off spec)." in strip_codes(c.eval("local f = ...; return f.status:GetText()", f))
    # the phase matches the import now: nothing left for Replace
    assert c.eval("local f = ...; return f.replace:IsEnabled()", f) is False
    # a pick the import doesn't have: Replace would empty it, and asks first
    c.eval("ns.BiS:SetSlot(2, 2, 'main', ...)", NECKLACE)
    w.tick(0.1)
    assert c.eval("local f = ...; return f.replace:GetText()", f) == "Replace P2 (1)"
    c.click(c.eval("local f = ...; return f.replace", f))
    w.tick(0.1)
    log = c.eval_py("local log = __MOCK.popup_log or {}; local e = log[#log]; return e and e.text or ''")
    assert "Replace every pick in P2 (main and off spec) with the imported list?" in log, log
    no_errors(w)


@case
def a_big_paste_is_read_whole_from_on_char():
    w, c = setup()
    c.eval("ns.ImportExport:Open('import')")
    filler = "\r\n".join(tmb_row("wishlist", "Guildie%03d" % i, "Mage", 1, "Garona's Signet Ring", GARONA)
                         for i in range(160))
    text = TMB_HEADER + "\r\n" + filler + "\r\n" + tmb_csv().split("\r\n", 1)[1]
    assert len(text) > 16000
    eb = c.eval("return ns.ImportExport:GetFrame().import.box.eb")
    c.eval("T_paste(...)", eb, text)
    assert len(c.eval("local eb = ...; return eb:GetText()", eb)) == 16000   # the box shows the start only
    w.tick(0.1)
    st = c.eval_py("local s = ns.ImportExport:GetImportState(); return { #s.source, s.character or '', #s.parsed.characters }")
    assert st == [len(text), "Alice", 162], st
    # typing a little after it reads the box again
    c.eval("local eb = ...; __MOCK.type_text(eb, ''); ", eb)
    w.tick(0.1)
    assert c.eval("return ns.ImportExport:GetImportState().source") == ""
    no_errors(w)


@case
def export_tab_formats_and_choices():
    w, c = setup()
    gear_with_gems(c)
    c.eval("ns.BiS:ApplyTemplate(1, { [1] = { %d, %d }, [13] = { %d, 0 } }, true)" % (GREATHELM, WITCH_HAT, RIBBON))
    open_mybis(c, w)
    c.eval("ns.ImportExport:Open('export')")
    w.tick(0.1)
    st = c.eval_py("local s = ns.ImportExport:GetImportState(); return { s.what, s.format, s.exPhase }")
    assert st == ["bis", "wowsims", 1], st
    text = c.eval("return ns.ImportExport:GetExportText()")
    assert text == c.eval("return ns.BiSExport:WoWSims((ns.BiSExport:PhaseSpecs(1)))"), text[:80]
    p = c.eval("return ns.ImportExport:GetFrame().export")
    help_text = c.eval("local p = ...; return p.help:GetText()", p)
    assert "Import > Addon" in help_text and "use what you wear" in help_text, help_text
    c.eval("ns.ImportExport:SetExport(nil, 'bulk')")
    assert json.loads(c.eval("return ns.ImportExport:GetExportText()"))["items"][0]["id"] == GREATHELM
    # Current gear can't be a Bulk list: back to WoWSims
    c.eval("ns.ImportExport:SetExport('gear')")
    st = c.eval_py("local s = ns.ImportExport:GetImportState(); return { s.what, s.format }")
    assert st == ["gear", "wowsims"], st
    assert c.eval("return ns.ImportExport:GetExportText()") == c.eval("return ns.BiSExport:WoWSims(ns.BiSExport:EquippedSpecs())")
    c.eval("ns.ImportExport:SetExport(nil, 'wowhead')")
    assert c.eval("return ns.ImportExport:GetExportText()").startswith("https://www.wowhead.com/tbc/gear-planner/")
    # Bulk switches back to the BiS list
    c.eval("ns.ImportExport:SetExport(nil, 'bulk')")
    assert c.eval("return ns.ImportExport:GetImportState().what") == "bis"
    no_errors(w)


if __name__ == "__main__":
    run_all()
