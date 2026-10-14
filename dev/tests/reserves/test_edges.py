"""Loot reserves (1.4.3): the edges. A new loot authority takes the list over, a full 40-player list fits the wire,
chat commands from outside the raid or without "!" in raid chat are left alone, the roll pop-up for reservers / others
/ a pug on the guild's item, and turning reserves off mid-raid."""
from rv_common import *  # noqa: F403

R = Runner("reserves / edges")


def setup(n=1, held=None):
    r = reserve_raid()
    open_reserves(r, n=n, held=held)
    return r


@R.case
def a_new_raid_leader_takes_the_list_over_and_answers_whispers():
    r = setup(n=1)
    w = r.w
    whisper(r, "Yuri", "!sr Ruby Drape")
    r["Carol"].eval("ns.Reserves:Reserve(...)", MINDBLADE)
    w.tick(2)
    # Alice leaves: Bob leads now (the loot authority)
    rest = [c for n, c in r.c.items() if n != "Alice"]
    w.make_raid(rest, leader=r["Bob"], extra_members=r.extra)
    w.tick(8)
    assert r["Bob"].eval("return ns.GroupRules:IsAuthority()")
    L = r["Bob"].eval_py("local L = ns.Reserves:Get(); return L and { by = L.by }")
    assert L and L["by"] == key("Bob"), L
    assert reserves_of(r["Gina"], "Yuri") == [RUBY_DRAPE]
    c0 = len(w.chat_log)
    whisper(r, "Zed", "!sr Mindblade", to="Bob")
    w.tick(2)
    assert any(l.startswith("[DZ] Reserved") for l in whispers_to(r, "Zed", c0, frm="Bob")), whispers_to(r, "Zed", c0, frm="Bob")
    assert reserves_of(r["Carol"], "Zed") == [MINDBLADE]
    w.assert_no_errors()


@R.case
def a_full_40_player_list_fits_and_arrives_whole():
    r = setup(n=3)
    a = r["Alice"]
    items = a.eval_py("local out = {}; for id in pairs(ns.Reserves:RaidLoot('Karazhan')) do out[#out + 1] = id end; "
                      "table.sort(out); return out")
    names = ["Pug%02d" % i for i in range(40)]
    for i, nm in enumerate(names):
        for k in range(3):
            a.eval("ns.Reserves:AddFor(...)", key(nm), items[(i * 3 + k) % len(items)], "s", True)
    r.w.tick(3)
    n = r["Carol"].eval_py("local n = 0; for _ in pairs(ns.Reserves:Get().r) do n = n + 1 end; return n")
    assert n == 40, n
    assert reserves_of(r["Carol"], "Pug39") == sorted(items[(39 * 3 + k) % len(items)] for k in range(3))
    # the whole list stays under a member's message cap (a host who isn't on the council)
    size = a.eval_py("local L = ns.Reserves:Get(); local r = {}; for key, set in pairs(L.r) do local p = {}; "
                     "for id, s in pairs(set) do p[#p + 1] = id .. ':' .. s end; r[key] = table.concat(p, ',') end; "
                     "local ok, wire = ns.Comm:Fits({ t = 'RVS', id = L.id, by = L.by, v = L.v, at = L.at, rk = L.rk, "
                     "n = L.n, o = 1, h = L.h, r = r }); return wire")
    assert size and size < 3000, size
    r.w.assert_no_errors()


@R.case
def chat_commands_that_are_not_for_us():
    r = setup(n=1)
    w = r.w
    c0 = len(w.chat_log)
    # someone outside the raid
    r["Alice"].fire("CHAT_MSG_WHISPER", "!sr Ruby Drape", key("Stranger"), "", "", "Stranger", "", 0, 0, "", 0, 1,
                    make_guid("Stranger", REALM), 0, False, False, False, False)
    # raid chat without the "!"
    r["Alice"].fire("CHAT_MSG_RAID", "sr list", key("Carol"), "", "", "Carol", "", 0, 0, "", 0, 1,
                    make_guid("Carol", REALM), 0, False, False, False, False)
    # an ordinary whisper
    whisper(r, "Yuri", "hey can I get an invite to the next run?")
    w.tick(1)
    assert not [e for e in w.chat_log[c0:] if e["sender"] == key("Alice")], w.chat_log[c0:]
    # raid chat with "!": answered by whisper
    r["Alice"].fire("CHAT_MSG_RAID", "!sr list", key("Carol"), "", "", "Carol", "", 0, 0, "", 0, 1,
                    make_guid("Carol", REALM), 0, False, False, False, False)
    w.tick(1)
    assert whispers_to(r, "Carol", c0), w.chat_log[c0:]
    w.assert_no_errors()


@R.case
def the_roll_popup_for_reservers_others_and_a_pug_on_a_guild_item():
    r = setup(n=1, held=[THOUSAND_MARKS])
    w = r.w
    hugo = Client(w, "Hugo", class_file="WARRIOR", guild=None)
    hugo.load_addon()
    w.tick(3)
    r.c["Hugo"] = hugo
    r.form_raid(list(r.c.values()))
    w.tick(10)
    r["Bob"].eval("ns.Reserves:Reserve(...)", RUBY_DRAPE)
    whisper(r, "Yuri", "!sr Ruby Drape")
    w.tick(2)
    r["Alice"].open_loot([(RUBY_DRAPE, 4), (THOUSAND_MARKS, 4)])
    w.tick(2)
    start_roll(r, RUBY_DRAPE)
    w.tick(1)
    bob = rollframe_state(r["Bob"])
    assert bob["shown"] and "Your reserve" in strip_codes(bob["bis"]) and "Yuri" in strip_codes(bob["bis"]), bob
    carol = rollframe_state(r["Carol"])
    assert not carol["shown"], carol
    line = r["Carol"].eval_py("local t = ns.UI:GetToast('dz-reserve-line'); return t and t:IsShown() and "
                              "t.opts and t.opts.text or nil")
    assert line and "only they roll" in line, line
    # the guild's item: a pug with the addon gets the line, a guildie the pop-up
    r["Alice"].eval("local s = ns.Roll:GetActive(); if s then ns.Roll:End(s.id) end")
    w.tick(4)
    start_roll(r, THOUSAND_MARKS)
    w.tick(1)
    assert not rollframe_state(hugo)["shown"], rollframe_state(hugo)
    assert "Held for the guild" in strip_codes(rollframe_state(r["Carol"])["bis"]), rollframe_state(r["Carol"])
    w.assert_no_errors()


@R.case
def turning_reserves_off_mid_raid_goes_back_to_the_council():
    r = setup(n=1)
    w = r.w
    r["Bob"].eval("ns.Reserves:Reserve(...)", RUBY_DRAPE)
    w.tick(2)
    set_reserve_features(r, on=False)
    assert decide(r["Alice"], RUBY_DRAPE) == {}, decide(r["Alice"], RUBY_DRAPE)
    r["Alice"].open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    log0 = len(w.addon_log)
    start_roll(r, RUBY_DRAPE)
    RS = msgs_of_type(w, "RS", log0)
    assert RS and RS[0].get("rv") is None and RS[0]["pl"] == 0, RS
    # the list itself stays (turning them back on picks it up again)
    assert reserves_of(r["Carol"], "Bob") == [RUBY_DRAPE]
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)
