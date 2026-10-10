#!/usr/bin/env python
"""Loot-roll area: crafting materials (Nether Vortex from SSC trash, 2026-10-10).

A material is wanted through the crafts that use it: the council's drop panel groups its candidates by craft (who in
the guild crafts it, how many each candidate holds), the suggestion goes to whoever it completes a craft for, then the
closest; raiders' clients report their holdings (MH on the drop, h / f on their roll), the popup and the toast say
which craft it is for, and an awarded material shows the craft it counts toward with a Whisper to the crafter.

Run: luaenv\\Scripts\\python.exe tests\\loot-roll\\test_materials.py   [-k substring]
"""
from lr_common import *  # noqa: F401,F403

R = Runner("loot-roll / crafting materials")

VORTEX = 30183
BLASTING = 30038            # Belt of Blasting: tailoring, 2 Vortex (spell 36315)
LONG_ROAD = 30036           # Belt of the Long Road: tailoring, 2 Vortex (spell 36316)
RED_BELT = 30032            # Red Belt of Battle: blacksmithing, 2 Vortex
DEEP_SHADOW = 30040         # Belt of Deep Shadow: leatherworking, 2 Vortex
LIONHEART = 28430           # Lionheart Executioner: swordsmith, 5 Vortex
SPELL_BLASTING = 36315
SID_WAIST, SID_MH2 = 8, 15
SSC_TRASH_GUID = "Creature-0-1-2-3-21251-00ABCD"   # Underbog Colossus

# Bob (mage, council) wants Belt of Blasting, Carol (warrior) Red Belt of Battle + Lionheart (off-spec), Erin (rogue)
# Belt of Deep Shadow; Dave (priest) knows Tailoring's Belt of Blasting.
MAT_BIS = {
    "Alice": [(1, SID_HEAD, "main", JUSTICAR_DIADEM)],
    "Bob": [(2, SID_WAIST, "main", BLASTING)],
    "Carol": [(2, SID_WAIST, "main", RED_BELT)],
    "Erin": [(2, SID_WAIST, "main", DEEP_SHADOW)],
}


def ssc_raid(bis=None, **kw):
    r = Raid(bis=bis if bis is not None else MAT_BIS, encounter=False, instance=False, **kw)
    r.w.enter_instance("Serpentshrine Cavern", 548, max_players=25)
    r.w.tick(1)
    return r


def drop_vortex(r, who="Alice", n=1, tick=3):
    r[who].open_loot([(VORTEX, 4)] * n, source_guid=SSC_TRASH_GUID)
    r.w.tick(tick)


def give(c, item, count):
    c.set_bags({(0, 1): (item, count)})


def mat_block(c):
    """The Vortex card on c's drop panel: heads (craft, crafter text), rows (key, pill, status, pips text), sub,
    buttons."""
    return c.eval_py(r"""
        local DP = ns.DropPanel
        if not (DP.frame and DP.frame:IsShown()) then return nil end
        for _, b in ipairs(DP.blocks) do
          if b:IsShown() and b.itemID == 30183 then
            local heads, rows, btns = {}, {}, {}
            for _, h in ipairs(b.matHeads or {}) do
              if h:IsShown() then heads[#heads + 1] = { item = h.use.item, crafter = h.crafter:GetText() or "",
                per = h.per:GetText() or "" } end
            end
            for _, r in ipairs(b.rows) do
              if r:IsShown() then
                rows[#rows + 1] = { key = r.data and r.data.key or false, craft = r.data and r.data.craft or false,
                  status = r.status:GetText() or "", tag = r.tag:GetText() or "",
                  pips = r.pips:IsShown() and r.pips.count:GetText() or false,
                  more = r.moreText:IsShown() and r.moreText:GetText() or false }
              end
            end
            for _, btn in ipairs(b.actionButtons) do
              if btn:IsShown() then btns[#btns + 1] = btn:GetText() or "?" end
            end
            local m = b.made and b.made:IsShown() and b.made
            return { heads = heads, rows = rows, sub = b.sub:GetText() or "", buttons = btns,
              awarded = b.awarded:IsShown() and b.awarded:GetText() or "",
              none = b.none:IsShown() and b.none:GetText() or "",
              made = m and { name = m.name:GetText() or "", prog = m.prog:GetText() or "",
                crafter = m.crafter:GetText() or "", whisper = m.whisper:IsShown() and true or false } or false }
          end
        end
        return nil""")


def learn_blasting(r, name="Dave"):
    """`name` opens Tailoring with Belt of Blasting known: the guild learns they craft it."""
    c = r[name]
    c.eval("__MOCK.SPELL_NAMES[...] = 'Belt of Blasting'", SPELL_BLASTING)
    c.eval("""
      __MOCK.skills = { { name = "Professions", header = true }, { name = "Tailoring", rank = 375, max = 375 } }""")
    c.fire("SKILL_LINES_CHANGED")
    c.eval("__MOCK.tradeskill = { name = 'Tailoring', rank = 375, max = 375, rows = { "
           "{ name = 'Recipes', header = true }, { name = 'Belt of Blasting', spell = ..., item = 30038 } } }",
           SPELL_BLASTING)
    c.fire("TRADE_SKILL_SHOW")
    r.w.tick(40)


# ------------------------------------------------------------------------------------------------------------------
@R.case
def material_data_knows_vortex_crafts():
    r = ssc_raid(bis={}, sync=False, raid=False)
    a = r["Alice"]
    assert a.eval("return ns.Materials:IsMaterial(...)", VORTEX) is True
    assert a.eval("return ns.Materials:IsMaterial(...)", RUBY_DRAPE) is False, "gear is never a material"
    uses = {u["item"]: u for u in a.eval_py("return ns.Materials:GetUses(...)", VORTEX)}
    assert uses[BLASTING]["count"] == 2 and uses[LIONHEART]["count"] == 5, uses
    assert uses[LIONHEART]["spec"] == "Swordsmith", uses[LIONHEART]
    assert uses[BLASTING]["prof"]["name"] == "Tailoring", uses[BLASTING]


@R.case
def council_card_groups_wanters_by_craft():
    r = ssc_raid()
    drop_vortex(r)
    for name in ("Alice", "Bob"):
        blk = mat_block(r[name])
        assert blk, "%s: no Vortex card" % name
        assert blk["sub"] == "Crafting material", blk["sub"]
        crafts = [h["item"] for h in blk["heads"]]
        assert set(crafts) == {BLASTING, RED_BELT, DEEP_SHADOW}, crafts
        assert all(h["per"] == "2 per craft" for h in blk["heads"]), blk["heads"]
        keys = [x["key"] for x in blk["rows"] if x["key"]]
        assert sorted(keys) == sorted([key("Bob"), key("Carol"), key("Erin")]), keys
        assert all(x["pips"] == "0/2" for x in blk["rows"] if x["key"]), blk["rows"]
        assert any(x["more"] and "more crafts use it" in x["more"] for x in blk["rows"]), blk["rows"]
        assert "Nobody" in blk["heads"][0]["crafter"] or "No " in blk["heads"][0]["crafter"], blk["heads"]
        assert blk["buttons"][-1].startswith("Award to "), blk["buttons"]


@R.case
def holdings_report_moves_whoever_it_completes_to_the_top():
    r = ssc_raid()
    give(r["Erin"], VORTEX, 1)
    r.w.tick(1)
    log0 = len(r.w.addon_log)
    drop_vortex(r)
    mh = msgs_of_type(r.w, "MH", log0)
    senders = {m["_sender"]: m for m in mh}
    assert key("Erin") in senders and senders[key("Erin")]["h"] == 1 and senders[key("Erin")]["f"] == DEEP_SHADOW, mh
    assert key("Bob") in senders and senders[key("Bob")]["h"] == 0, "every wanter reports, also with none: %r" % mh
    assert key("Dave") not in senders, "no craft on Dave's lists: no report"
    blk = mat_block(r["Alice"])
    first = [x for x in blk["rows"] if x["key"]][0]
    assert first["key"] == key("Erin") and first["pips"] == "1/2", blk["rows"]
    assert "completes" in strip_codes(first["status"]), first
    assert blk["heads"][0]["item"] == DEEP_SHADOW, blk["heads"]
    assert blk["buttons"][-1] == "Award to Erin", blk["buttons"]


@R.case
def loot_log_estimate_counts_earlier_vortexes():
    r = ssc_raid()
    a = r["Alice"]
    assert a.eval("return ns.Ledger:Award(...) ~= nil", VORTEX, key("Carol"), "") is True
    r.w.tick(3)
    # before anyone's client reported (no drop yet): the loot log's count
    w = a.eval_py("local w = ns.Materials:GetWants(...).byKey[select(2, ...)]; return { held = w.held, src = w.heldSrc,"
                  " completes = w.completes }", VORTEX, key("Carol"))
    assert w == {"held": 1, "src": "log", "completes": True}, w
    # Carol's own client knows better (she holds none now): its report wins
    drop_vortex(r)
    w = a.eval_py("local w = ns.Materials:GetWants(...).byKey[select(2, ...)]; return { held = w.held, src = w.heldSrc }",
                  VORTEX, key("Carol"))
    assert w == {"held": 0, "src": "report"}, w


@R.case
def roll_suggests_who_it_completes_over_a_higher_roll():
    r = ssc_raid()
    give(r["Bob"], VORTEX, 1)
    r.w.tick(1)
    drop_vortex(r)
    a = r["Alice"]
    log0 = len(r.w.addon_log)
    a.eval("ns.DropPanel:StartRoll(...)", VORTEX)
    r.w.tick(1)
    for name, v in (("Bob", 12), ("Carol", 95), ("Erin", 60)):
        r[name].eval("local s = ns.Roll:GetActive(); ns.Roll:RespondRoll(s.id)")
        r.w.player_roll(r[name], v)
    r.w.tick(2)
    rr = [m for m in msgs_of_type(r.w, "RR", log0) if m["_sender"] == key("Bob")]
    assert rr and rr[0].get("h") == 1 and rr[0].get("f") == BLASTING, rr
    res = a.eval_py("local s = ns.Roll:GetActive(); return ns.Roll:GetResults(s.id)")
    top = [x for x in res if x.get("suggested")]
    assert len(top) == 1 and top[0]["key"] == key("Bob"), [(x["key"], x.get("roll"), x.get("left")) for x in res]
    assert [x["key"] for x in res][:3] == [key("Bob"), key("Carol"), key("Erin")], [(x["key"], x.get("left")) for x in res]
    blk = mat_block(a)
    tags = {x["key"]: strip_codes(x["tag"]) for x in blk["rows"] if x["key"]}
    assert tags[key("Bob")] == "1/2" and tags[key("Carol")] == "0/2", tags


@R.case
def raider_popup_and_toast_say_which_craft():
    r = ssc_raid(bis=dict(MAT_BIS, Bob=[(2, SID_WAIST, "main", BLASTING), (2, SID_WAIST, "alt", LONG_ROAD)]))
    give(r["Bob"], VORTEX, 1)
    r.w.tick(1)
    drop_vortex(r)
    b = r["Bob"]
    t = toast_state(b)
    assert t["item"] == VORTEX and "For Belt of Blasting" in strip_codes(t["text"] or ""), t
    assert any("for [Belt of Blasting] on your BiS list (you have 1 of 2)" in strip_codes(l) for l in printed_lines(b)), \
        printed_lines(b)[-5:]
    r["Alice"].eval("ns.DropPanel:StartRoll(...)", VORTEX)
    r.w.tick(1)
    st = b.eval_py("""local f = ns.RollFrame.frame
        return { bis = f.bis:GetText(), pill = f.bisPill:IsShown() and f.bisPill.fs:GetText() or false,
                 hold = f.wearLabel:GetText(), pick = f.forBtn:IsShown() }""")
    assert st["pill"] == "BiS" and strip_codes(st["bis"]).startswith("for Belt of Blasting"), st
    assert strip_codes(st["bis"]).endswith(" +1") and st["pick"] is True, st
    assert strip_codes(st["hold"]) == "You have 1 of 2 · completes it", st
    # picking the other craft tells the council right away
    log0 = len(r.w.addon_log)
    b.eval("ns.Materials:SetOwnPick(...)", VORTEX, LONG_ROAD)
    r.w.tick(1)
    mh = [m for m in msgs_of_type(r.w, "MH", log0) if m["_sender"] == key("Bob")]
    assert mh and mh[-1]["f"] == LONG_ROAD, mh
    w = r["Alice"].eval_py("return ns.Materials:GetWants(...).byKey[select(2, ...)].craft", VORTEX, key("Bob"))
    assert w == LONG_ROAD, w


@R.case
def awarded_vortex_shows_the_craft_and_the_crafter():
    r = ssc_raid()
    learn_blasting(r, "Dave")
    give(r["Bob"], VORTEX, 1)
    r.w.tick(1)
    drop_vortex(r)
    a = r["Alice"]
    blk = mat_block(a)
    head = [h for h in blk["heads"] if h["item"] == BLASTING][0]
    assert "Dave" in strip_codes(head["crafter"]), head
    assert blk["buttons"][-1] == "Award to Bob", blk["buttons"]
    a.eval("local DP = ns.DropPanel; for _, b in ipairs(DP.blocks) do if b.itemID == 30183 then DP:AwardMaterialBest(b) end end")
    r.w.tick(3)
    for p in ("DISASTERZONE_CONFIRM_AWARD", "DISASTERZONE_GIVE_ITEM"):
        if p in a.popups():
            a.accept_popup(p)
    r.w.tick(3)
    blk = mat_block(a)
    assert "Bob" in strip_codes(blk["awarded"]), blk
    m = blk["made"]
    assert m and "Belt of Blasting" in strip_codes(m["name"]) and strip_codes(m["prog"]) in ("2/2 · ready to craft", "2/2"), m   # (the short form when the line is tight)
    assert "Dave" in strip_codes(m["crafter"]) and m["whisper"] is True, m
    n0 = len(r.w.chat_log)
    a.eval("local DP = ns.DropPanel; for _, b in ipairs(DP.blocks) do if b.itemID == 30183 then DP:WhisperCrafter(b) end end")
    r.w.tick(1)
    sent = [x for x in r.w.chat_log[n0:] if x["chat_type"] == "WHISPER"]
    assert len(sent) == 1 and "Dave" in str(sent[0]["target"]), sent
    assert strip_codes(sent[0]["text"]) == "Bob has 2/2 [Nether Vortex] for [Belt of Blasting]", sent


@R.case
def announce_names_crafts_and_holdings():
    r = ssc_raid()
    give(r["Bob"], VORTEX, 1)
    r.w.tick(1)
    drop_vortex(r)
    line = strip_codes(r["Alice"].eval("return ns.DropPanel:BuildAnnounceLine(...)", VORTEX))
    assert "Belt of Blasting: Bob 1/2" in line and "Red Belt of Battle: Carol 0/2" in line, line


@R.case
def a_drop_nobody_crafts_for_says_so():
    r = ssc_raid(bis={"Alice": [(1, SID_HEAD, "main", JUSTICAR_DIADEM)]})
    drop_vortex(r)
    blk = mat_block(r["Alice"])
    assert blk["heads"] == [] and "No craft that uses it" in blk["none"], blk


if __name__ == "__main__":
    main(R)
