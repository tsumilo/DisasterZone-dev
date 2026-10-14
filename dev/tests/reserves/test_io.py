"""Loot reserves in and out (1.4.3, Core/ReserveIO.lua): softres.it's CSV and its Gargul string, LootReserve's CSV, Gargul's
own CSV; the exports read back by Python the way the other tools would read them (zlib + Base64 + JSON for Gargul)."""
import base64
import csv
import io
import json
import zlib

from rv_common import *  # noqa: F403

R = Runner("reserves / import and export")


def setup(n=2, held=None):
    r = reserve_raid()
    open_reserves(r, n=n, held=held)
    return r


def do_import(r, text):
    return r["Alice"].eval_py("local ok, msg, ref = ns.ReserveIO:Import(...); return { ok = ok, msg = msg, "
                              "refused = ref and #ref or 0 }", text)


SOFTRES_CSV = ("﻿Item,ItemId,From,Name,Class,Spec,Note,Date\n"
               "Ruby Drape of the Mysticant,28766,Prince Malchezaar,Yuri,Druid,Balance,,2026-10-14 19:01:12\n"
               "\"Ring of a Thousand Marks\",28757,Prince Malchezaar,carol,Warrior,Fury,\"main, please\",2026-10-14 19:02:40\n"
               "Nathrezim Mindblade,28770,Prince Malchezaar,Zed,Warrior,Arms,,2026-10-14 19:03:00\n"
               "Nathrezim Mindblade,28770,Prince Malchezaar,Latecomer,Rogue,Combat,,2026-10-14 19:04:00\n"
               "Ruby Drape of the Mysticant,28766,Prince Malchezaar,Yuri,Druid,Balance,,2026-10-14 19:01:12\n"
               "Thunderfury,19019,Somewhere,Zed,Warrior,Arms,,2026-10-14 19:05:00\n")


@R.case
def a_softres_csv_lands_in_the_list():
    r = setup()
    res = do_import(r, SOFTRES_CSV)
    assert res["ok"], res
    a = r["Alice"]
    assert reserves_of(a, "Yuri") == [RUBY_DRAPE]                 # (the same row twice: once)
    assert reserves_of(a, "Carol") == [THOUSAND_MARKS]            # (a lower-case name)
    assert reserves_of(a, "Zed") == [MINDBLADE]                   # (Thunderfury isn't Karazhan's loot: refused)
    assert reserves_of(a, "Latecomer") == [MINDBLADE]             # (not here yet: kept for when they come)
    assert a.eval_py("return ns.Reserves:SourceOf(...)", key("Yuri"), RUBY_DRAPE) == "s"
    assert "4 reserves imported" in res["msg"] and "1 skipped" in res["msg"], res
    r.w.tick(2)
    assert reserves_of(r["Bob"], "Latecomer") == [MINDBLADE]
    r.w.assert_no_errors()


@R.case
def the_gargul_string_with_hard_reserves():
    r = setup()
    data = {"metadata": {"id": "ABC123", "url": "https://softres.it/raid/ABC123"},
            "softreserves": [{"name": "Yuri", "class": "druid", "note": "", "plusOnes": 0, "items": [{"id": RUBY_DRAPE}]},
                             {"name": "Frank", "class": "hunter", "items": [{"id": FARSTRIDER}, {"id": JADE_RING}]}],
            "hardreserves": [{"id": HELM_CHAMPION, "for": "Alice", "note": ""}]}
    text = base64.b64encode(zlib.compress(json.dumps(data).encode())).decode()
    res = do_import(r, text)
    assert res["ok"], res
    a = r["Alice"]
    assert reserves_of(a, "Yuri") == [RUBY_DRAPE]
    assert reserves_of(a, "Frank") == sorted([FARSTRIDER, JADE_RING])
    assert a.eval("return ns.Reserves:IsHeld(...)", HELM_CHAMPION)
    assert "held for the guild" in res["msg"], res
    r.w.assert_no_errors()


@R.case
def lootreserves_csv_and_gargul_csv():
    r = setup()
    lr = "Player,Class,Plus,ExtraReserves,RollBonus,Item,Count\nYuri,DRUID,0,0,0,28766,1\nDave,PRIEST,1,0,0,28763,1\n"
    assert do_import(r, lr)["ok"]
    gc = "28770,Erin,Gina\n28757,Frank\n"
    assert do_import(r, gc)["ok"]
    a = r["Alice"]
    assert reserves_of(a, "Yuri") == [RUBY_DRAPE] and reserves_of(a, "Dave") == [JADE_RING]
    assert reserves_of(a, "Erin") == [MINDBLADE] and reserves_of(a, "Gina") == [MINDBLADE]
    assert reserves_of(a, "Frank") == [THOUSAND_MARKS]
    r.w.assert_no_errors()


@R.case
def garbage_is_turned_down_politely():
    r = setup()
    for text in ("", "hello there", "a,b,c\n1,2,3\n", "!!!notbase64!!!"):
        res = do_import(r, text)
        assert res["ok"] is False and res["msg"], (text, res)
    # a raider can't import
    res = r["Carol"].eval_py("local ok, msg = ns.ReserveIO:Import(...); return { ok = ok, msg = msg }", SOFTRES_CSV)
    assert res["ok"] is False, res
    r.w.assert_no_errors()


@R.case
def exports_read_back_like_the_other_tools_read_them():
    r = setup(held=[HELM_CHAMPION])
    do_import(r, SOFTRES_CSV)
    a = r["Alice"]
    # softres.it columns
    rows = list(csv.DictReader(io.StringIO(a.eval_py("return ns.ReserveIO:Export('csv')"))))
    got = sorted((x["Name"], int(x["ItemId"])) for x in rows)
    assert got == sorted([("Yuri", RUBY_DRAPE), ("Carol", THOUSAND_MARKS), ("Zed", MINDBLADE),
                          ("Latecomer", MINDBLADE)]), got
    assert all(x["From"] == "Prince Malchezaar" for x in rows), rows
    # LootReserve's columns, imported again into a fresh list: the same reserves
    lr = a.eval_py("return ns.ReserveIO:Export('lootreserve')")
    assert lr.splitlines()[0] == "Player,Class,Plus,ExtraReserves,RollBonus,Item,Count", lr
    # Gargul: Base64 of zlib-packed JSON
    g = a.eval_py("return ns.ReserveIO:Export('gargul')")
    data = json.loads(zlib.decompress(base64.b64decode(g)))
    soft = {s["name"]: [i["id"] for i in s["items"]] for s in data["softreserves"]}
    assert soft["Yuri"] == [RUBY_DRAPE] and soft["Latecomer"] == [MINDBLADE], soft
    assert [h["id"] for h in data["hardreserves"]] == [HELM_CHAMPION], data
    a.eval("ns.Reserves:Clear()")
    open_reserves(r, n=2)
    assert do_import(r, lr)["ok"]
    assert reserves_of(a, "Latecomer") == [MINDBLADE]
    a.eval("ns.Reserves:Clear()")
    open_reserves(r, n=2)
    assert do_import(r, g)["ok"]
    assert reserves_of(a, "Carol") == [THOUSAND_MARKS]
    assert a.eval("return ns.Reserves:IsHeld(...)", HELM_CHAMPION)
    # raid chat: every line fits
    lines = a.eval_py("return ns.ReserveIO:ChatLines()")
    assert lines and all(len(l.encode()) <= 255 for l in lines), lines
    r.w.assert_no_errors()


@R.case
def the_wrap_up_after_a_night():
    r = setup(n=1, held=[HELM_CHAMPION])
    w = r.w
    whisper(r, "Yuri", "!sr Ruby Drape")
    r["Bob"].eval("ns.Reserves:Reserve(...)", RUBY_DRAPE)
    r["Dave"].eval("ns.Reserves:Reserve(...)", JADE_RING)
    w.tick(2)
    r["Alice"].open_loot([(RUBY_DRAPE, 4), (JADE_RING, 4), (MINDBLADE, 4)])
    w.tick(2)
    s1 = start_roll(r, RUBY_DRAPE)
    w.player_roll("Yuri", 70)
    w.player_roll("Bob", 20)
    w.tick(1)
    r["Alice"].eval("ns.Roll:MarkAwardedExternally(...)", s1["id"], key("Yuri"))
    w.tick(3)
    s2 = start_roll(r, JADE_RING)
    w.tick(1)
    r["Alice"].eval("ns.Roll:MarkAwardedExternally(...)", s2["id"], key("Dave"))
    w.tick(3)
    rows = r["Alice"].eval_py("local out = {}; for i, x in ipairs(ns.ReserveIO:WrapUp()) do out[i] = { i = x.itemID, "
                              "w = x.winner, how = x.how, roll = x.roll } end; return out")
    assert rows == [{"i": RUBY_DRAPE, "w": key("Yuri"), "how": "reserve roll", "roll": 70},
                    {"i": JADE_RING, "w": key("Dave"), "how": "only reserve"}], rows
    c0 = len(w.chat_log)
    r["Alice"].eval("ns.ReservesUI:PostWrap()")
    w.tick(1)
    posted = [strip_codes(e["text"]) for e in w.chat_log[c0:]]
    assert posted and "Yuri (reserve roll 70)" in posted[0] and "Dave (only reserve)" in posted[0], posted
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)
